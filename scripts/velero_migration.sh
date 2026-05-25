#!/bin/bash
##############################################################
# OpenShift Cluster Migration - Velero Backup & Restore Script
# File: velero_migration.sh
# Purpose: Backup all namespaces from OCP3 (on-prem) and
#          restore them to OCP4 (AWS cloud) using Velero.
# Usage:
#   ./velero_migration.sh backup   -- Run on OCP3 cluster
#   ./velero_migration.sh restore  -- Run on OCP4 cluster
##############################################################

set -euo pipefail

# ---- CONFIGURATION ----
S3_BUCKET="ocp4-prod-velero-backup-prod"
AWS_REGION="ap-south-1"
BACKUP_NAME="ocp3-full-migration-$(date +%Y%m%d%H%M)"
RESTORE_NAME="ocp4-restore-${BACKUP_NAME}"
VELERO_NAMESPACE="velero"

# Namespaces to migrate (space-separated)
NAMESPACES_TO_MIGRATE=(
  "production"
  "staging"
  "monitoring"
  "logging"
  "ci-cd"
)

# ---- COLORS ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---- PRE-FLIGHT CHECKS ----
preflight_checks() {
  log_info "Running pre-flight checks..."
  command -v oc    >/dev/null 2>&1 || log_error "oc CLI not found"
  command -v velero >/dev/null 2>&1 || log_error "velero CLI not found"
  command -v aws   >/dev/null 2>&1 || log_error "aws CLI not found"

  oc whoami >/dev/null 2>&1 || log_error "Not logged into OpenShift cluster"
  log_info "Pre-flight checks passed."
}

# ---- INSTALL VELERO ON CLUSTER ----
install_velero() {
  log_info "Installing Velero with AWS plugin..."
  velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket "${S3_BUCKET}" \
    --backup-location-config region="${AWS_REGION}" \
    --snapshot-location-config region="${AWS_REGION}" \
    --secret-file ./credentials-velero \
    --use-volume-snapshots=true \
    --default-volumes-to-restic

  log_info "Waiting for Velero pod to be ready..."
  oc wait --for=condition=Ready pod -l app.kubernetes.io/name=velero \
    -n "${VELERO_NAMESPACE}" --timeout=120s
  log_info "Velero installed and ready."
}

# ---- BACKUP FUNCTION (Run on OCP3) ----
run_backup() {
  preflight_checks
  log_info "Starting backup of OCP3 cluster to S3 bucket: ${S3_BUCKET}"

  # Backup each namespace individually for granular control
  for NS in "${NAMESPACES_TO_MIGRATE[@]}"; do
    BACKUP="${BACKUP_NAME}-${NS}"
    log_info "Backing up namespace: ${NS} -> backup: ${BACKUP}"

    velero backup create "${BACKUP}" \
      --include-namespaces "${NS}" \
      --include-cluster-resources=true \
      --storage-location default \
      --volume-snapshot-locations default \
      --ttl 720h \
      --wait

    STATUS=$(velero backup get "${BACKUP}" -o jsonpath='{.status.phase}')
    if [[ "${STATUS}" == "Completed" ]]; then
      log_info "Backup ${BACKUP} completed successfully."
    else
      log_error "Backup ${BACKUP} failed with status: ${STATUS}"
    fi
  done

  # Also do a full cluster-scoped resource backup (CRDs, ClusterRoles, etc.)
  log_info "Backing up cluster-scoped resources..."
  velero backup create "${BACKUP_NAME}-cluster-resources" \
    --include-cluster-resources=true \
    --exclude-namespaces "kube-system,openshift,openshift-.*" \
    --wait

  log_info "All backups complete. Listing backups:"
  velero backup get
}

# ---- RESTORE FUNCTION (Run on OCP4) ----
run_restore() {
  preflight_checks
  log_info "Starting restore to OCP4 cluster from S3 bucket: ${S3_BUCKET}"

  # Restore cluster-scoped resources first
  log_info "Restoring cluster-scoped resources..."
  velero restore create "${RESTORE_NAME}-cluster" \
    --from-backup "${BACKUP_NAME}-cluster-resources" \
    --include-cluster-resources=true \
    --wait

  # Restore each namespace
  for NS in "${NAMESPACES_TO_MIGRATE[@]}"; do
    BACKUP="${BACKUP_NAME}-${NS}"
    RESTORE="${RESTORE_NAME}-${NS}"
    log_info "Restoring namespace: ${NS} from backup: ${BACKUP}"

    # Create the namespace if it doesn't exist
    oc get namespace "${NS}" 2>/dev/null || oc create namespace "${NS}"

    velero restore create "${RESTORE}" \
      --from-backup "${BACKUP}" \
      --include-namespaces "${NS}" \
      --restore-volumes=true \
      --wait

    STATUS=$(velero restore get "${RESTORE}" -o jsonpath='{.status.phase}')
    if [[ "${STATUS}" == "Completed" ]]; then
      log_info "Restore ${RESTORE} completed successfully."
    else
      log_warn "Restore ${RESTORE} finished with status: ${STATUS}. Check warnings."
    fi
  done

  log_info "All restores complete. Verifying pods..."
  for NS in "${NAMESPACES_TO_MIGRATE[@]}"; do
    echo ""
    log_info "--- Pods in ${NS} ---"
    oc get pods -n "${NS}"
  done
}

# ---- VALIDATE MIGRATION ----
validate_migration() {
  log_info "Running post-migration validation..."
  PASS=0; FAIL=0

  for NS in "${NAMESPACES_TO_MIGRATE[@]}"; do
    TOTAL=$(oc get pods -n "${NS}" --no-headers 2>/dev/null | wc -l)
    RUNNING=$(oc get pods -n "${NS}" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    log_info "Namespace ${NS}: ${RUNNING}/${TOTAL} pods Running"
    [[ "${RUNNING}" -eq "${TOTAL}" && "${TOTAL}" -gt 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  done

  echo ""
  log_info "Validation Summary: PASS=${PASS}, FAIL=${FAIL}"
  [[ "${FAIL}" -gt 0 ]] && log_warn "Some namespaces have non-running pods. Investigate before cutting over DNS."
}

# ---- MAIN ----
ACTION="${1:-help}"
case "${ACTION}" in
  install) install_velero ;;
  backup)  run_backup ;;
  restore) run_restore ;;
  validate) validate_migration ;;
  *)
    echo "Usage: $0 {install|backup|restore|validate}"
    echo "  install   - Install Velero on current cluster"
    echo "  backup    - Backup all namespaces from OCP3 (run on OCP3)"
    echo "  restore   - Restore all namespaces to OCP4 (run on OCP4)"
    echo "  validate  - Validate pods post-migration"
    ;;
esac
