# TaskApp — Operations Runbook

> **Audience**: DevOps engineers with AWS CLI, kubectl, and kops access  
> **Last Updated**: 2026-04-08  
> **Cluster**: `taskapp.cynthia-devops.com` | **Region**: `us-east-1`

---

## Prerequisites

```bash
# Required tools and minimum versions
terraform   >= 1.7.0
kops        >= 1.28.0
kubectl     >= 1.28.0
aws-cli     >= 2.15.0
kubeseal    >= 0.26.0    # for Sealed Secrets
helm        >= 3.14.0

# Environment variables — set these before any procedure
export AWS_PROFILE=kops-admin
export KOPS_STATE_STORE=s3://taskapp-kops-state
export CLUSTER_NAME=taskapp.cynthia-devops.com
export AWS_REGION=us-east-1
```

---

## 1. Initial Deployment

### 1.1 Bootstrap Terraform Infrastructure

```bash
cd terraform/

# Initialise remote backend (S3 + DynamoDB already exist — bootstrapped separately)
terraform init \
  -backend-config="bucket=taskapp-tf-state" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=taskapp-tf-locks"

# Review the plan — expect ~30 resources on first apply
terraform plan -out=tfplan

# Apply — creates VPC, subnets, IGW, NAT GWs, Route53 zone, IAM roles, S3 buckets
terraform apply tfplan
```

> **DNS delegation**: After `terraform apply`, Terraform outputs the 4 Route53 NS records.  
> Log in to your domain registrar and update the nameservers for `cynthia-devops.com` to these values.  
> Propagation typically takes 5–30 minutes. Verify with:
> ```bash
> dig NS cynthia-devops.com +short
> ```

### 1.2 Create the Kops Cluster

```bash
# Generate the cluster spec — adjust instance types / node counts as needed
kops create cluster \
  --name=${CLUSTER_NAME} \
  --state=${KOPS_STATE_STORE} \
  --cloud=aws \
  --master-count=3 \
  --master-size=t3.medium \
  --master-zones=us-east-1a,us-east-1b,us-east-1c \
  --node-count=3 \
  --node-size=t3.large \
  --zones=us-east-1a,us-east-1b,us-east-1c \
  --networking=calico \
  --topology=private \
  --bastion \
  --dns-zone=cynthia-devops.com \
  --vpc=$(terraform -chdir=terraform output -raw vpc_id) \
  --subnets=$(terraform -chdir=terraform output -raw private_subnet_ids) \
  --utility-subnets=$(terraform -chdir=terraform output -raw public_subnet_ids) \
  --yes

# Preview what kops will create on AWS
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE}

# Actually provision EC2 instances and cluster components
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes

# Wait for the cluster to become ready (~10–15 minutes)
kops validate cluster --state=${KOPS_STATE_STORE} --wait 15m
```

### 1.3 Configure kubectl

```bash
kops export kubeconfig ${CLUSTER_NAME} \
  --state=${KOPS_STATE_STORE} \
  --admin

# Confirm nodes are Ready
kubectl get nodes -o wide

# Expected output — 3 masters + 3 workers, all Ready
```

### 1.4 Deploy Cluster Add-ons (Helm)

```bash
# cert-manager
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.5 \
  --set installCRDs=true

# NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.replicaCount=2

# Sealed Secrets controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system

# Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=${CLUSTER_NAME} \
  --set awsRegion=${AWS_REGION}
```

### 1.5 Create the ClusterIssuer for Let's Encrypt

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: chimomacynthia@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

### 1.6 Deploy Application Manifests

```bash
# Seal and apply database credentials first
kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 32)" \
  --from-literal=POSTGRES_USER=taskapp \
  --from-literal=POSTGRES_DB=taskapp \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system \
             --controller-name sealed-secrets \
             --format yaml \
  > k8s/base/postgres-sealed-secret.yaml

git add k8s/base/postgres-sealed-secret.yaml && git commit -m "chore: update sealed db secret"

# Apply all manifests
kubectl apply -k k8s/overlays/production

# Watch rollout
kubectl rollout status deployment/frontend -n taskapp
kubectl rollout status deployment/backend -n taskapp
kubectl rollout status statefulset/postgres -n taskapp
```

---

## 2. Scaling

### 2.1 Scale Application Pods Manually

```bash
# Scale backend replicas (e.g., ahead of expected traffic spike)
kubectl scale deployment backend --replicas=4 -n taskapp

# Scale frontend
kubectl scale deployment frontend --replicas=4 -n taskapp

# Verify pods spread across AZs
kubectl get pods -n taskapp -o wide | grep -E "frontend|backend"
```

### 2.2 Scale Worker Nodes (Cluster Autoscaler)

The Cluster Autoscaler handles node scaling automatically when pods are `Pending` due to insufficient resources. To adjust the autoscaler bounds:

```bash
# Edit the worker instance group
kops edit ig nodes-us-east-1a --state=${KOPS_STATE_STORE}
# Change minSize / maxSize, then:
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes
kops rolling-update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes
```

### 2.3 Vertical Scaling (Change Instance Type)

```bash
# Change workers from t3.large to t3.xlarge
kops edit ig nodes --state=${KOPS_STATE_STORE}
# Edit spec.machineType, then:
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes

# Rolling update replaces nodes one at a time with zero downtime
kops rolling-update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} \
  --instance-group=nodes --yes
```

---

## 3. Secret Rotation

### 3.1 Rotate PostgreSQL Password

```bash
# 1. Generate new password
NEW_PG_PASSWORD=$(openssl rand -base64 32)

# 2. Update the secret inside PostgreSQL first (connect via exec)
POSTGRES_POD=$(kubectl get pod -n taskapp -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n taskapp ${POSTGRES_POD} -- \
  psql -U taskapp -c "ALTER USER taskapp PASSWORD '${NEW_PG_PASSWORD}';"

# 3. Create and seal new Kubernetes secret
kubectl create secret generic postgres-credentials \
  --from-literal=POSTGRES_PASSWORD="${NEW_PG_PASSWORD}" \
  --from-literal=POSTGRES_USER=taskapp \
  --from-literal=POSTGRES_DB=taskapp \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system \
             --controller-name sealed-secrets \
             --format yaml \
  > k8s/base/postgres-sealed-secret.yaml

# 4. Apply and restart backend to pick up new credentials
kubectl apply -f k8s/base/postgres-sealed-secret.yaml
kubectl rollout restart deployment/backend -n taskapp

# 5. Verify backend pods come up healthy
kubectl rollout status deployment/backend -n taskapp

# 6. Commit the new sealed secret
git add k8s/base/postgres-sealed-secret.yaml
git commit -m "security: rotate postgres credentials $(date +%Y-%m-%d)"
git push
```

### 3.2 Rotate AWS IAM Access Keys (for kops-admin)

```bash
# 1. Create new access key
aws iam create-access-key --user-name kops-admin \
  | jq '{AccessKeyId: .AccessKey.AccessKeyId, SecretAccessKey: .AccessKey.SecretAccessKey}'

# 2. Update ~/.aws/credentials with new key, set AWS_PROFILE, verify access
aws sts get-caller-identity

# 3. Inactivate (not yet delete) old key
aws iam update-access-key \
  --user-name kops-admin \
  --access-key-id <OLD_KEY_ID> \
  --status Inactive

# 4. Confirm all operations work for 24 hours, then delete old key
aws iam delete-access-key \
  --user-name kops-admin \
  --access-key-id <OLD_KEY_ID>
```

### 3.3 Rotate Sealed Secrets Master Key

> ⚠️ **Do this during a maintenance window.** All existing SealedSecrets must be re-sealed after the key is rotated.

```bash
# 1. Backup current sealing key
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key-backup-$(date +%Y%m%d).yaml

# Store this backup in a secure location (NOT git)
aws s3 cp sealed-secrets-master-key-backup-$(date +%Y%m%d).yaml \
  s3://taskapp-kops-state/sealed-secrets-keys/ \
  --sse aws:kms

# 2. Delete current key to force rotation
kubectl delete secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key

# 3. Restart the controller — it generates a new key
kubectl rollout restart deployment/sealed-secrets -n kube-system

# 4. Re-seal all secrets and re-apply (repeat section 1.6 secret steps)
```

---

## 4. Troubleshooting

### 4.1 Cluster Not Validating

```bash
kops validate cluster --state=${KOPS_STATE_STORE}
# If errors, inspect node statuses:
kubectl get nodes
kubectl describe node <node-name>

# Check master component logs via bastion (if node is unreachable via kubectl)
ssh -J admin@<bastion-ip> admin@<master-private-ip>
sudo journalctl -u kube-apiserver -f
sudo journalctl -u etcd -f
```

### 4.2 Pods Stuck in Pending

```bash
kubectl describe pod <pod-name> -n taskapp
# Look for: "Insufficient memory", "no nodes available", "Unschedulable"

# If resource pressure — check node capacity
kubectl top nodes
kubectl describe nodes | grep -A5 "Allocated resources"

# If PVC issue — check volume binding
kubectl get pvc -n taskapp
kubectl describe pvc <pvc-name> -n taskapp
# Common fix: EBS volume stuck in "Released" state in wrong AZ
```

### 4.3 Certificate Not Issuing

```bash
# Check ClusterIssuer status
kubectl describe clusterissuer letsencrypt-prod

# Check Certificate resource
kubectl get certificate -n taskapp
kubectl describe certificate taskapp-tls -n taskapp

# Check CertificateRequest and Order
kubectl get certificaterequest -n taskapp
kubectl get order -n taskapp

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f

# Common causes:
# - HTTP-01 challenge path not reachable (check ingress /.well-known/acme-challenge/)
# - Rate limit hit (5 duplicate certs/week) — use letsencrypt-staging issuer to test
# - DNS not yet propagated for the domain
```

### 4.4 Backend Pods CrashLoopBackOff

```bash
kubectl logs -n taskapp -l app=backend --previous

# Common causes and fixes:
# 1. DB connection refused → check postgres pod is running, service resolves
kubectl exec -n taskapp deploy/backend -- nc -zv postgres-service 5432

# 2. Wrong DB password → verify sealed secret decrypted correctly
kubectl get secret postgres-credentials -n taskapp -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# 3. Out of memory → check resource limits, increase if needed
kubectl describe pod -n taskapp -l app=backend | grep -A3 "Limits\|OOMKilled"
```

### 4.5 Ingress Returns 502/503

```bash
# Check NGINX ingress controller pods
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

# Check backend service endpoints are populated
kubectl get endpoints -n taskapp

# If endpoints are empty, pods are not passing readiness probes
kubectl describe pod -n taskapp -l app=backend | grep -A10 "Readiness"

# Check ingress resource routing rules
kubectl describe ingress taskapp-ingress -n taskapp
```

### 4.6 etcd Backup Verification

```bash
# List recent backups
aws s3 ls s3://taskapp-kops-state/backups/etcd/ --recursive | sort | tail -10

# Manually trigger a backup (runs the backup CronJob immediately)
kubectl create job --from=cronjob/etcd-backup manual-backup-$(date +%s) -n kube-system

# Verify backup file is valid (must be non-zero bytes)
aws s3 ls s3://taskapp-kops-state/backups/etcd/ | awk '{print $3, $4}' | tail -5
```

### 4.7 Node Not Joining Cluster

```bash
# Check Auto Scaling Group activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name nodes.${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  | jq '.Activities[0]'

# Check cloud-init log on the problematic node (via bastion)
ssh -J admin@<bastion-ip> admin@<node-private-ip>
sudo cat /var/log/cloud-init-output.log | tail -50
sudo journalctl -u kubelet -f
```

---

## 5. Routine Maintenance

### 5.1 Kubernetes Version Upgrade

```bash
# 1. Update kops binary to target version
# 2. Update cluster spec
kops edit cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE}
# Change kubernetesVersion: 1.29.x

# 3. Preview changes
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE}

# 4. Apply and rolling-update
kops update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes
kops rolling-update cluster ${CLUSTER_NAME} --state=${KOPS_STATE_STORE} --yes

# 5. Validate
kops validate cluster --state=${KOPS_STATE_STORE}
kubectl version
```

### 5.2 Daily Health Check (can be scripted/cron)

```bash
kops validate cluster --state=${KOPS_STATE_STORE}
kubectl get nodes
kubectl get pods -n taskapp
kubectl top nodes
aws s3 ls s3://taskapp-kops-state/backups/etcd/ | tail -3
```