# 🚀 OCP4 CI/CD Pipeline — GitHub Actions + ArgoCD

A production-grade **Continuous Integration & Continuous Deployment** pipeline that builds, scans, pushes, and deploys containerized applications to **OpenShift Container Platform 4 (OCP4)** using **GitHub Actions** and **ArgoCD**, with automated post-deployment smoke testing.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Pipeline Jobs](#pipeline-jobs)
- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [GitHub Secrets Configuration](#github-secrets-configuration)
- [Environment Variables](#environment-variables)
- [Commands Reference](#commands-reference)
- [Smoke Test Details](#smoke-test-details)
- [Rollback Strategy](#rollback-strategy)
- [Troubleshooting](#troubleshooting)

---

## Overview

This pipeline automates the full software delivery lifecycle:

```
Code Push → Build & Test → Container Build → Image Scan → Push to Registry
    → ArgoCD GitOps Deploy → Smoke Test → ✅ Production Live
```

The workflow triggers on every push to the `main` branch and runs four sequential jobs, each depending on the successful completion of the previous one.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GitHub Actions                           │
│                                                                 │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │  JOB 1   │──▶│  JOB 2   │──▶│  JOB 3   │──▶│   JOB 4    │  │
│  │  Build   │   │   Scan   │   │  ArgoCD  │   │ Smoke Test │  │
│  │  & Push  │   │  Image   │   │  Deploy  │   │  on OCP4   │  │
│  └──────────┘   └──────────┘   └──────────┘   └────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         │                              │               │
         ▼                              ▼               ▼
   Container Registry             ArgoCD Server     OCP4 Cluster
   (Quay / ECR / GHCR)           (GitOps Sync)    (Running Pods)
```

---

## Pipeline Jobs

### JOB 1 — Build & Push
- Checks out source code
- Builds the Docker/Podman container image
- Tags the image with the Git SHA (`IMAGE_TAG`)
- Pushes to the configured container registry

### JOB 2 — Image Scan
- Pulls the newly built image
- Runs a vulnerability scanner (e.g., Trivy, Grype, or Clair)
- Fails the pipeline if critical CVEs are found
- Ensures no insecure images are deployed to production

### JOB 3 — ArgoCD Deploy
- Triggers an ArgoCD application sync
- Updates the image tag in the GitOps manifest repository
- ArgoCD reconciles the cluster state with the desired Git state
- Waits for ArgoCD to confirm the sync is complete

### JOB 4 — Smoke Test on OCP4 *(documented in detail below)*
- Installs the OpenShift CLI (`oc`)
- Authenticates to the OCP4 cluster
- Waits for the deployment rollout to complete (up to 180s)
- Verifies at least one pod is in `Running` state
- Performs an HTTP health-check against the live OpenShift Route
- Rolls back on failure

---

## Prerequisites

Before using this pipeline, ensure the following are in place:

| Requirement | Details |
|---|---|
| OpenShift 4.x Cluster | With a project/namespace for the app |
| ArgoCD | Installed in-cluster or externally, app already configured |
| Container Registry | Quay.io, AWS ECR, GHCR, or similar |
| GitHub Repository Secrets | See [Secrets section](#github-secrets-configuration) |
| OCP4 Service Account Token | With deployment permissions in the target namespace |
| App exposes `/health` endpoint | Must return HTTP 200 when healthy |

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       └── deploy.yml          # Main CI/CD pipeline definition
├── Dockerfile                  # Container build definition
├── k8s/                        # Kubernetes/OCP manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   └── route.yaml
├── argocd/
│   └── application.yaml        # ArgoCD Application definition
└── README.md
```

---

## GitHub Secrets Configuration

Navigate to **Settings → Secrets and variables → Actions** in your GitHub repository and add the following secrets:

| Secret Name | Description | Example |
|---|---|---|
| `OCP4_SERVER` | OCP4 API server URL | `https://api.cluster.example.com:6443` |
| `OCP4_TOKEN` | Service account token for OCP4 auth | `sha256~xxxxxxxxxxxx` |
| `REGISTRY_USERNAME` | Container registry username | `myuser` |
| `REGISTRY_PASSWORD` | Container registry password or token | `mypassword` |
| `ARGOCD_SERVER` | ArgoCD server URL | `argocd.example.com` |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token | `eyJhbGci...` |

> ⚠️ **Never commit secrets to your repository.** Always use GitHub Secrets or an external vault.

---

## Environment Variables

These are defined at the top of `deploy.yml` and referenced throughout the pipeline:

```yaml
env:
  APP_NAME: my-application          # Name of the OCP Deployment and Route
  OCP_NAMESPACE: my-namespace       # OCP4 project/namespace
  IMAGE_TAG: ${{ github.sha }}      # Unique tag per commit (Git SHA)
  REGISTRY: quay.io/myorg           # Container image registry base URL
```

---

## Commands Reference

### OpenShift CLI (`oc`) Commands

#### Authentication

```bash
# Login to OCP4 cluster with token
oc login <OCP4_SERVER> --token=<OCP4_TOKEN> --insecure-skip-tls-verify=true

# Verify current login context
oc whoami
oc whoami --show-server
```

#### Deployment Management

```bash
# Check rollout status (waits until complete or timeout)
oc rollout status deployment/<APP_NAME> -n <NAMESPACE> --timeout=180s

# View rollout history
oc rollout history deployment/<APP_NAME> -n <NAMESPACE>

# Trigger a new rollout manually
oc rollout restart deployment/<APP_NAME> -n <NAMESPACE>

# Rollback to the previous deployment revision
oc rollout undo deployment/<APP_NAME> -n <NAMESPACE>

# Rollback to a specific revision
oc rollout undo deployment/<APP_NAME> -n <NAMESPACE> --to-revision=<NUMBER>
```

#### Pod Management

```bash
# List all pods in a namespace
oc get pods -n <NAMESPACE>

# List pods filtered by app label
oc get pods -n <NAMESPACE> -l app=<APP_NAME>

# List only Running pods
oc get pods -n <NAMESPACE> -l app=<APP_NAME> --field-selector=status.phase=Running

# Count running pods (used in smoke test)
oc get pods -n <NAMESPACE> \
  -l app=<APP_NAME> \
  --field-selector=status.phase=Running \
  --no-headers | wc -l

# Describe a specific pod (useful for debugging)
oc describe pod <POD_NAME> -n <NAMESPACE>

# View pod logs
oc logs <POD_NAME> -n <NAMESPACE>

# Stream live logs
oc logs -f <POD_NAME> -n <NAMESPACE>

# View logs from previous crashed container
oc logs <POD_NAME> -n <NAMESPACE> --previous
```

#### Routes & Networking

```bash
# Get all routes in namespace
oc get routes -n <NAMESPACE>

# Get the hostname of a specific route
oc get route <APP_NAME> -n <NAMESPACE> -o jsonpath='{.spec.host}'

# Describe a route
oc describe route <APP_NAME> -n <NAMESPACE>
```

#### Namespace / Project Management

```bash
# List all projects
oc get projects

# Switch to a project
oc project <NAMESPACE>

# Create a new project
oc new-project <NAMESPACE>
```

#### Deployment & Image

```bash
# Get deployment details
oc get deployment <APP_NAME> -n <NAMESPACE>

# Update the image tag in a deployment
oc set image deployment/<APP_NAME> \
  <CONTAINER_NAME>=<REGISTRY>/<IMAGE>:<NEW_TAG> \
  -n <NAMESPACE>

# Scale deployment
oc scale deployment/<APP_NAME> --replicas=3 -n <NAMESPACE>
```

---

### ArgoCD CLI Commands

#### Authentication

```bash
# Login to ArgoCD
argocd login <ARGOCD_SERVER> --auth-token <ARGOCD_AUTH_TOKEN> --insecure

# Login with username/password
argocd login <ARGOCD_SERVER> --username admin --password <PASSWORD>
```

#### Application Management

```bash
# List all ArgoCD applications
argocd app list

# Get application status
argocd app get <APP_NAME>

# Trigger a manual sync
argocd app sync <APP_NAME>

# Sync and wait until healthy
argocd app sync <APP_NAME> --timeout 300

# Force sync (bypass cache)
argocd app sync <APP_NAME> --force

# Get application health and sync status
argocd app get <APP_NAME> --show-params

# Hard refresh (re-fetch from Git)
argocd app get <APP_NAME> --hard-refresh

# Rollback to a previous deployed version
argocd app rollback <APP_NAME> <REVISION_ID>

# View sync history
argocd app history <APP_NAME>
```

---

### Docker / Container Commands

```bash
# Build the container image
docker build -t <REGISTRY>/<IMAGE>:<TAG> .

# Push image to registry
docker push <REGISTRY>/<IMAGE>:<TAG>

# Pull image from registry
docker pull <REGISTRY>/<IMAGE>:<TAG>

# Login to container registry
docker login <REGISTRY> -u <USERNAME> -p <PASSWORD>

# Tag an existing image
docker tag <SOURCE_IMAGE>:<TAG> <REGISTRY>/<IMAGE>:<NEW_TAG>
```

---

### Health Check (curl)

```bash
# Perform HTTP health check (used in smoke test)
HTTP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://<ROUTE_HOST>/health")
echo "HTTP Status: ${HTTP_STATUS}"

# Verbose curl for debugging
curl -v -k "https://<ROUTE_HOST>/health"

# With timeout
curl --max-time 10 -sk -o /dev/null -w "%{http_code}" "https://<ROUTE_HOST>/health"
```

**`curl` flags used in the pipeline:**

| Flag | Meaning |
|---|---|
| `-s` | Silent mode — no progress bar |
| `-k` | Skip TLS/SSL certificate verification |
| `-o /dev/null` | Discard response body |
| `-w "%{http_code}"` | Print only the HTTP status code |

---

## Smoke Test Details

The smoke test (JOB 4) performs two layers of verification after every deployment:

### Layer 1 — Kubernetes/OCP Health
```bash
# Wait for rollout
oc rollout status deployment/<APP_NAME> -n <NAMESPACE> --timeout=180s

# Count running pods
RUNNING=$(oc get pods -n <NAMESPACE> \
  -l app=<APP_NAME> \
  --field-selector=status.phase=Running \
  --no-headers | wc -l)

[ "${RUNNING}" -gt "0" ] || exit 1
```

### Layer 2 — Application Health (HTTP)
```bash
# Get dynamic route URL
ROUTE_HOST=$(oc get route <APP_NAME> -n <NAMESPACE> -o jsonpath='{.spec.host}')

# Hit health endpoint
HTTP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://${ROUTE_HOST}/health")

[ "${HTTP_STATUS}" == "200" ] || exit 1
```

---

## Rollback Strategy

If the smoke test fails, the pipeline automatically attempts a rollback:

```bash
# Automatic rollback triggered on failure
oc rollout undo deployment/<APP_NAME> -n <NAMESPACE> || true
```

The `|| true` ensures the pipeline step itself does not fail if the undo command encounters an issue (e.g., no previous revision exists).

ArgoCD will also **self-heal** the application if the deployment drifts from the desired Git state — meaning the GitOps source of truth always wins.

**Manual rollback steps:**

```bash
# 1. Login to cluster
oc login <OCP4_SERVER> --token=<OCP4_TOKEN>

# 2. Check rollout history
oc rollout history deployment/<APP_NAME> -n <NAMESPACE>

# 3. Rollback to previous
oc rollout undo deployment/<APP_NAME> -n <NAMESPACE>

# 4. Verify pods are healthy
oc get pods -n <NAMESPACE> -l app=<APP_NAME>

# 5. Also revert ArgoCD to previous Git revision
argocd app rollback <APP_NAME> <PREVIOUS_REVISION>
```

---

## Troubleshooting

### Pipeline fails at "Login to OCP4 cluster"
- Verify `OCP4_SERVER` secret is the correct API URL (port 6443 usually)
- Verify `OCP4_TOKEN` has not expired — regenerate from OCP4 service account
- If using a self-signed cert, ensure `--insecure-skip-tls-verify=true` is present

### Pipeline fails at "Verify all pods are Running"
- Check pod events: `oc describe pod <POD_NAME> -n <NAMESPACE>`
- Check image pull errors: the registry credentials may need updating
- Check resource quotas: `oc describe quota -n <NAMESPACE>`

### Pipeline fails at "HTTP health-check"
- Ensure the app exposes a `/health` endpoint returning HTTP `200`
- Check if the route exists: `oc get routes -n <NAMESPACE>`
- Test manually: `curl -vk https://<ROUTE_HOST>/health`
- Check app logs for startup errors: `oc logs -l app=<APP_NAME> -n <NAMESPACE>`

### ArgoCD sync stuck
```bash
# Force a hard refresh and sync
argocd app sync <APP_NAME> --force --hard-refresh

# Check ArgoCD application events
argocd app get <APP_NAME>
```

---

## License

MIT — see [LICENSE](./LICENSE) for details.
