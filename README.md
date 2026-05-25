# 🚀 OpenShift 3 → OpenShift 4 Migration on AWS (ROSA)

A complete, production-grade migration project to move workloads from an **on-premise OpenShift 3 cluster** to a **Red Hat OpenShift Service on AWS (ROSA / OCP4)** cluster.

---

## 📐 Architecture Overview

```
ON-PREMISE (OCP3)                        AWS CLOUD (OCP4 / ROSA)
─────────────────────                    ──────────────────────────────────
  DeploymentConfigs                         Deployments (apps/v1)
  Routes                      ──────►       Ingress / Routes
  Services                   Velero         Services
  ConfigMaps                 Backup &       ConfigMaps
  Secrets                    Restore        Secrets
  PVCs                                      PVCs (EBS/EFS)
  RBAC                                      RBAC
```

---

## 🗂️ Project Structure

```
ocp3-to-ocp4-migration/
│
├── terraform/                        # AWS Infrastructure as Code
│   ├── main.tf                       # VPC, Subnets, IGW, NAT, S3, Route53, IAM
│   └── variables.tf                  # All configurable variables
│
├── ansible/
│   └── ocp3_export_configs.yml       # Export all workloads from OCP3
│
├── scripts/
│   └── velero_migration.sh           # Backup (OCP3) & Restore (OCP4) via Velero
│
├── .github/
│   └── workflows/
│       └── ocp4-deploy.yml           # CI/CD: Build → Scan → Push ECR → ArgoCD Deploy
│
├── docs/
│   └── PROJECT_EXPLANATION.txt       # Full project explanation & interview Q&A
│
└── README.md
```

---

## 🛠️ Tech Stack

| Tool | Purpose |
|------|---------|
| **Terraform** | Provision AWS infrastructure (VPC, S3, IAM, Route53) |
| **Ansible** | Export OCP3 workload configs to YAML |
| **Velero** | Backup OCP3 namespaces → S3, Restore to OCP4 |
| **GitHub Actions** | CI/CD pipeline (Build, Scan, Deploy) |
| **ArgoCD** | GitOps-based deployment to OCP4 |
| **Amazon ECR** | Docker image registry |
| **Trivy** | Container vulnerability scanning |
| **Helm** | Kubernetes package manager for app deployment |

---

## 🔄 Migration Flow (Step by Step)

### Phase 1 — Provision AWS Infrastructure
```bash
cd terraform/
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Phase 2 — Export OCP3 Configurations
```bash
ansible-playbook ansible/ocp3_export_configs.yml -i inventory.ini \
  -e "ocp3_token=<your-token>"
```

### Phase 3 — Velero Backup from OCP3
```bash
# Run on OCP3 cluster
./scripts/velero_migration.sh install
./scripts/velero_migration.sh backup
```

### Phase 4 — Velero Restore to OCP4
```bash
# Run on OCP4 cluster
./scripts/velero_migration.sh install
./scripts/velero_migration.sh restore
./scripts/velero_migration.sh validate
```

### Phase 5 — CI/CD via GitHub Actions + ArgoCD
Push to `main` branch → GitHub Actions automatically:
1. Builds Docker image
2. Scans with Trivy
3. Pushes to ECR
4. Updates Helm values
5. ArgoCD syncs to OCP4
6. Smoke tests run

---

## 🔐 Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |
| `AWS_REGION` | e.g. `ap-south-1` |
| `ECR_REGISTRY` | e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com` |
| `OCP4_SERVER` | `https://api.ocp4-prod.example.com:6443` |
| `OCP4_TOKEN` | OpenShift service account token |
| `ARGOCD_SERVER` | ArgoCD server hostname |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token |

---

## 📦 Namespaces Being Migrated

- `production`
- `staging`
- `monitoring`
- `logging`
- `ci-cd`

---

## 🌍 AWS Region

**ap-south-1** (Mumbai) — all resources are provisioned here.

---

## 👤 Author

Built as a complete OCP3 → OCP4 cloud migration project.
