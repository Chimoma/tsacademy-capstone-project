# TeamFlow — Cloud-Native Task Manager

**Capstone Project | TS Academy DevOps Engineering Program | 2026**
**Author**: Oluwatobiloba Durodola
**Live URL**: https://taskapp.cynthia-devops.com
**API**: https://api.cynthia-devops.com/api/health

---

## Overview

TeamFlow is a production-grade, cloud-native task management application deployed on AWS using Kubernetes (Kops), Terraform, and modern DevOps practices. It features a React frontend, Flask REST API, and PostgreSQL database — all running in a highly available, multi-AZ Kubernetes cluster with automated SSL, encrypted secrets, and zero-downtime deployments.

---

## Architecture Summary

```
Internet → Route53 → NLB → NGINX Ingress (cert-manager/Let's Encrypt)
                                  ├── frontend (React/Nginx) × 2 pods
                                  ├── backend  (Flask API)   × 2 pods
                                  └── postgres (StatefulSet) × 1 pod (EBS gp3)

VPC: 10.0.0.0/16 — 3 private subnets + 3 utility subnets across us-east-1a/b/c
Control Plane: 3 × t3.medium masters (one per AZ, etcd quorum)
Workers: 3 × t3.large nodes (autoscaling 3–9)
```

See [docs/architecture.md](docs/architecture.md) for full design, CIDR rationale, and HA strategy.

---

## Repository Structure

```
.
├── Dockerfile.backend              # Flask API container image
├── Dockerfile.frontend             # React/Nginx container image (VITE_API_URL baked in)
├── docs/
│   ├── architecture.md             # System design, CIDR rationale, HA strategy, security model
│   ├── runbook.md                  # Operational procedures: deploy, scale, rotate secrets, troubleshoot
│   └── cost-analysis.md            # Monthly AWS cost breakdown (~$271/month baseline)
├── k8s/
│   ├── base/                       # Reusable Kubernetes manifests
│   │   ├── backend/                # Deployment, Service, ConfigMap, SealedSecret
│   │   ├── frontend/               # Deployment, Service, ConfigMap
│   │   ├── postgres/               # StatefulSet, Service, StorageClass, SealedSecret
│   │   ├── cert-manager/           # ClusterIssuer (Let's Encrypt prod)
│   │   ├── namespace.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       └── production/             # ECR image patches + ingress rules for cynthia-devops.com
├── kops/
│   ├── cluster.yaml                # Kops cluster spec (private topology, Calico, etcd S3 backups)
│   └── instancegroups.yaml         # Master + worker instance group definitions
├── scripts/
│   ├── destroy.sh                  # Full teardown: K8s workloads → Kops → Terraform → state
│   └── kubeseal                    # kubeseal binary for sealing secrets locally
├── taskapp_backend/                # Flask REST API
│   ├── app/                        # App factory, routes, models, JWT auth
│   ├── migrations/                 # Alembic migration scripts
│   ├── tests/                      # Pytest test suite
│   └── requirements.txt
├── taskapp_frontend/               # React + TypeScript SPA
│   ├── src/
│   │   ├── components/             # KanbanColumn, TaskCard, TaskForm, ProtectedRoute
│   │   ├── contexts/               # AuthContext (JWT state management)
│   │   ├── pages/                  # Landing, Login, SignUp, Dashboard
│   │   ├── services/               # api.ts — centralised API abstraction layer
│   │   └── types/                  # TypeScript interfaces
│   └── nginx.conf                  # Nginx config for React Router + static asset caching
└── terraform/
    ├── main.tf                     # Root module wiring vpc + iam + dns
    ├── backend.tf                  # Remote state: S3 bucket + DynamoDB lock table
    ├── variables.tf / outputs.tf
    └── modules/
        ├── vpc/                    # VPC, subnets, IGW, NAT Gateways, route tables
        ├── iam/                    # kops-admin + terraform-deployer roles, instance profiles
        └── dns/                    # Route53 hosted zone for cynthia-devops.com
```

---

## Quickstart

### Prerequisites

| Tool | Min Version |
|---|---|
| AWS CLI | 2.15 |
| Terraform | 1.7 |
| Kops | 1.28 |
| kubectl | 1.28 |
| Helm | 3.14 |
| kubeseal | 0.36 |
| Docker | 24 |

### 1. Configure environment

```bash
export AWS_PROFILE=kops-admin
export AWS_REGION=us-east-1
export KOPS_STATE_STORE=s3://kops-state-cynthia-taskapp-2026
export CLUSTER_NAME=k8s.cynthia-devops.com
```

### 2. Provision AWS infrastructure (Terraform)

```bash
cd terraform/
terraform init \
  -backend-config="bucket=taskapp-tf-state" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=taskapp-tf-locks"
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Create the Kubernetes cluster (Kops)

```bash
kops create -f kops/cluster.yaml
kops create -f kops/instancegroups.yaml
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes
kops validate cluster --state=${KOPS_STATE_STORE} --wait 15m
```

### 4. Install cluster add-ons (Helm)

```bash
# cert-manager
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.5 --set installCRDs=true

# NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer

# Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system
```

### 5. Build and push container images (ECR)

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  050751893161.dkr.ecr.us-east-1.amazonaws.com

# Frontend — VITE_API_URL must be set at build time
docker build \
  --build-arg VITE_API_URL=https://api.cynthia-devops.com/api \
  -t 050751893161.dkr.ecr.us-east-1.amazonaws.com/taskapp-frontend:v1.0.1 \
  -f Dockerfile.frontend taskapp_frontend/
docker push 050751893161.dkr.ecr.us-east-1.amazonaws.com/taskapp-frontend:v1.0.1

# Backend
docker build \
  -t 050751893161.dkr.ecr.us-east-1.amazonaws.com/taskapp-backend:v1.0.0 \
  -f Dockerfile.backend taskapp_backend/
docker push 050751893161.dkr.ecr.us-east-1.amazonaws.com/taskapp-backend:v1.0.0
```

### 6. Deploy the application

```bash
kubectl apply -k k8s/overlays/production
kubectl rollout status deployment/frontend -n taskapp
kubectl rollout status deployment/backend -n taskapp

# First deploy only — initialise database tables
kubectl exec -n taskapp deployment/backend -- python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('Tables created')
"
```

### 7. Verify

```bash
kubectl get pods -n taskapp
kubectl get certificate -n taskapp
curl https://api.cynthia-devops.com/api/health
```

---

## Application Access

| | URL |
|---|---|
| Frontend | https://taskapp.cynthia-devops.com |
| Backend API | https://api.cynthia-devops.com/api |
| Health check | https://api.cynthia-devops.com/api/health |

**Demo credentials**

| Username | Password |
|---|---|
| admin | admin123 |
| user | user123 |

---

## API Reference

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| POST | `/api/auth/signup` | No | Create account, returns JWT |
| POST | `/api/auth/login` | No | Login, returns JWT |
| GET | `/api/tasks` | JWT | List all tasks |
| POST | `/api/tasks` | JWT | Create task |
| PUT | `/api/tasks/:id` | JWT | Update task |
| DELETE | `/api/tasks/:id` | JWT | Delete task |
| GET | `/api/health` | No | Health + DB connectivity check |

---

## Infrastructure Highlights

| Requirement | Implementation |
|---|---|
| Multi-master HA | 3 Kops masters across us-east-1a/b/c |
| Private topology | All nodes in private subnets, no public IPs |
| etcd backups | S3 (`kops-state-cynthia-taskapp-2026/backups/etcd/`), 90-day retention |
| Encrypted storage | EBS volumes encrypted at rest |
| Secrets management | Bitnami Sealed Secrets (encrypted YAMLs committed to Git safely) |
| Zero-downtime deploys | `maxUnavailable: 0`, `maxSurge: 1` rolling update strategy |
| Auto-scaling | Cluster Autoscaler, 3–9 worker nodes |
| SSL/TLS | cert-manager + Let's Encrypt, auto-renews 30 days before expiry |
| Non-root pods | `runAsNonRoot: true`, `runAsUser: 1000` on backend |
| Cost (baseline) | ~$271/month on-demand; ~$120/month with RIs + Spot workers |

---

## Teardown

```bash
chmod +x scripts/destroy.sh
AWS_PROFILE=kops-admin ./scripts/destroy.sh
```

Flags: `--skip-k8s`, `--skip-kops`, `--skip-terraform`, `--nuke-state`, `--yes`

---

## Documentation

| Doc | Description |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture diagram, CIDR rationale, HA and security model |
| [docs/runbook.md](docs/runbook.md) | Deploy, scale, rotate secrets, troubleshoot |
| [docs/cost-analysis.md](docs/cost-analysis.md) | Full AWS cost breakdown with optimisation scenarios |

---

## Submission

- **Live URL**: https://taskapp.cynthia-devops.com
- **Submission form**: https://forms.gle/8WsQDXWqDhuYPFxk9
