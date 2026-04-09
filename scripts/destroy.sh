#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Tear down the TaskApp production infrastructure
#
# ORDER OF OPERATIONS (important — reversing this causes dependency errors):
#   1. Delete Kubernetes workloads (releases ELBs, EBS volumes)
#   2. kops delete cluster (terminates EC2, removes ASGs, SGs, Route53 records)
#   3. terraform destroy (removes VPC, subnets, IAM, S3, Route53 hosted zone)
#   4. (Optional) Delete Terraform state bucket + DynamoDB lock table
#
# USAGE:
#   chmod +x scripts/destroy.sh
#   AWS_PROFILE=kops-admin ./scripts/destroy.sh
#
# Flags:
#   --skip-k8s       Skip step 1 (workload deletion) — use if cluster is gone
#   --skip-kops      Skip step 2 (kops delete)       — use if cluster is gone
#   --skip-terraform Skip step 3 (terraform destroy)
#   --nuke-state     Also destroy the S3/DynamoDB backend state (IRREVERSIBLE)
#   --yes            Skip all confirmation prompts    — USE WITH EXTREME CAUTION
# =============================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fatal()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Defaults ─────────────────────────────────────────────────────────────────
SKIP_K8S=false
SKIP_KOPS=false
SKIP_TERRAFORM=false
NUKE_STATE=false
AUTO_YES=false

for arg in "$@"; do
  case $arg in
    --skip-k8s)       SKIP_K8S=true ;;
    --skip-kops)      SKIP_KOPS=true ;;
    --skip-terraform) SKIP_TERRAFORM=true ;;
    --nuke-state)     NUKE_STATE=true ;;
    --yes)            AUTO_YES=true ;;
    *)                fatal "Unknown argument: $arg" ;;
  esac
done

# ─── Configuration — edit these to match your environment ─────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-taskapp.cynthia-devops.com}"
KOPS_STATE_STORE="${KOPS_STATE_STORE:-s3://taskapp-kops-state}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TF_DIR="${TF_DIR:-$(dirname "$0")/../terraform}"
K8S_NAMESPACE="${K8S_NAMESPACE:-taskapp}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-taskapp-tf-state}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-taskapp-tf-locks}"

# ─── Pre-flight checks ────────────────────────────────────────────────────────
info "Running pre-flight checks..."

for cmd in aws kubectl kops terraform; do
  command -v "$cmd" &>/dev/null || fatal "$cmd is not installed or not in PATH"
done

aws sts get-caller-identity &>/dev/null || fatal "AWS credentials not configured (check AWS_PROFILE)"

CALLER=$(aws sts get-caller-identity --query 'Arn' --output text)
warn "You are authenticated as: ${CALLER}"
warn "Cluster:    ${CLUSTER_NAME}"
warn "Region:     ${AWS_REGION}"
warn "State:      ${KOPS_STATE_STORE}"

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ⚠  THIS WILL PERMANENTLY DESTROY ALL INFRASTRUCTURE  ⚠    ║${NC}"
echo -e "${RED}║     All EC2 instances, volumes, and DNS records will be     ║${NC}"
echo -e "${RED}║     deleted. Database data will be LOST unless backed up.   ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$AUTO_YES" == false ]]; then
  read -rp "Type the cluster name to confirm deletion [${CLUSTER_NAME}]: " CONFIRM
  [[ "$CONFIRM" == "$CLUSTER_NAME" ]] || fatal "Confirmation failed. Aborting."
fi

# ─── Step 0: Backup database ─────────────────────────────────────────────────
if [[ "$SKIP_K8S" == false ]]; then
  info "Step 0/4 — Taking a final PostgreSQL backup before deletion..."
  POSTGRES_POD=$(kubectl get pod -n "${K8S_NAMESPACE}" \
    -l app=postgres --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1 || true)

  if [[ -n "$POSTGRES_POD" ]]; then
    BACKUP_FILE="taskapp-final-backup-$(date +%Y%m%d-%H%M%S).sql.gz"
    kubectl exec -n "${K8S_NAMESPACE}" "${POSTGRES_POD}" -- \
      pg_dump -U taskapp taskapp | gzip > "/tmp/${BACKUP_FILE}"

    aws s3 cp "/tmp/${BACKUP_FILE}" \
      "s3://taskapp-kops-state/final-backups/${BACKUP_FILE}" \
      --region "${AWS_REGION}"
    info "Database backup saved to: s3://taskapp-kops-state/final-backups/${BACKUP_FILE}"
  else
    warn "No postgres pod found — skipping database backup"
  fi
fi

# ─── Step 1: Delete Kubernetes workloads ─────────────────────────────────────
if [[ "$SKIP_K8S" == false ]]; then
  info "Step 1/4 — Deleting Kubernetes workloads..."

  # Delete application namespace (releases EBS PVCs and CLoudWatch log groups)
  kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found=true --timeout=120s

  # Delete ingress controller (releases the NLB/ELB)
  info "Deleting NGINX Ingress Controller (releases load balancer)..."
  helm uninstall ingress-nginx --namespace ingress-nginx 2>/dev/null || true
  kubectl delete namespace ingress-nginx --ignore-not-found=true --timeout=120s

  # Delete cert-manager
  info "Deleting cert-manager..."
  helm uninstall cert-manager --namespace cert-manager 2>/dev/null || true
  kubectl delete namespace cert-manager --ignore-not-found=true --timeout=120s

  # Delete cluster-autoscaler
  helm uninstall cluster-autoscaler --namespace kube-system 2>/dev/null || true

  # Delete sealed-secrets controller
  helm uninstall sealed-secrets --namespace kube-system 2>/dev/null || true

  # Wait for AWS to release ELBs before kops tries to delete the VPC
  info "Waiting 60s for AWS to release load balancers..."
  sleep 60

  # Confirm no ELBs remain in the cluster VPC (kops delete will fail if ELBs exist)
  info "Checking for lingering ELBs..."
  ELB_COUNT=$(aws elb describe-load-balancers --region "${AWS_REGION}" \
    --query "length(LoadBalancerDescriptions[?VPCId==\`$(aws ec2 describe-vpcs \
      --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
      --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}")\`])" \
    --output text 2>/dev/null || echo "0")

  if [[ "$ELB_COUNT" -gt 0 ]]; then
    warn "${ELB_COUNT} ELB(s) still exist. Waiting additional 60s..."
    sleep 60
  fi

  info "Kubernetes workloads deleted."
else
  warn "Skipping Step 1 (--skip-k8s)"
fi

# ─── Step 2: Delete Kops cluster ─────────────────────────────────────────────
if [[ "$SKIP_KOPS" == false ]]; then
  info "Step 2/4 — Deleting Kops cluster: ${CLUSTER_NAME}"

  # Preview what kops will delete
  kops delete cluster \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    --region="${AWS_REGION}" 2>&1 | head -30 || true

  echo ""
  if [[ "$AUTO_YES" == false ]]; then
    read -rp "Proceed with kops cluster deletion? [y/N]: " KOPS_CONFIRM
    [[ "${KOPS_CONFIRM,,}" == "y" ]] || fatal "Aborting at kops deletion."
  fi

  kops delete cluster \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    --region="${AWS_REGION}" \
    --yes

  info "Kops cluster deleted."

  # Wait for EC2 instances to fully terminate before Terraform tries to delete the VPC
  info "Waiting 90s for EC2 instances to fully terminate..."
  sleep 90
else
  warn "Skipping Step 2 (--skip-kops)"
fi

# ─── Step 3: Terraform destroy ────────────────────────────────────────────────
if [[ "$SKIP_TERRAFORM" == false ]]; then
  info "Step 3/4 — Running terraform destroy..."

  cd "${TF_DIR}"

  terraform init \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=prod/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
    -reconfigure \
    -input=false 2>&1

  terraform plan -destroy -out=destroy.tfplan -input=false

  echo ""
  if [[ "$AUTO_YES" == false ]]; then
    read -rp "Apply terraform destroy plan? [y/N]: " TF_CONFIRM
    [[ "${TF_CONFIRM,,}" == "y" ]] || fatal "Aborting at terraform destroy."
  fi

  terraform apply destroy.tfplan

  info "Terraform infrastructure destroyed."
  cd - >/dev/null
else
  warn "Skipping Step 3 (--skip-terraform)"
fi

# ─── Step 4: (Optional) Delete state backends ─────────────────────────────────
if [[ "$NUKE_STATE" == true ]]; then
  warn "Step 4/4 — Deleting Terraform state backend and Kops state store..."
  warn "This will DELETE all infrastructure history. This CANNOT be undone."

  if [[ "$AUTO_YES" == false ]]; then
    read -rp "Really delete state buckets? Type 'delete state' to confirm: " STATE_CONFIRM
    [[ "$STATE_CONFIRM" == "delete state" ]] || fatal "Aborting state deletion."
  fi

  # Empty and delete Terraform state bucket
  info "Emptying and deleting S3 bucket: ${TF_STATE_BUCKET}"
  aws s3 rm "s3://${TF_STATE_BUCKET}" --recursive --region "${AWS_REGION}" || true
  aws s3api delete-bucket \
    --bucket "${TF_STATE_BUCKET}" \
    --region "${AWS_REGION}" || true

  # Empty and delete Kops state bucket
  KOPS_BUCKET="${KOPS_STATE_STORE#s3://}"
  info "Emptying and deleting S3 bucket: ${KOPS_BUCKET}"
  aws s3 rm "s3://${KOPS_BUCKET}" --recursive --region "${AWS_REGION}" || true
  aws s3api delete-bucket \
    --bucket "${KOPS_BUCKET}" \
    --region "${AWS_REGION}" || true

  # Delete DynamoDB lock table
  info "Deleting DynamoDB table: ${TF_LOCK_TABLE}"
  aws dynamodb delete-table \
    --table-name "${TF_LOCK_TABLE}" \
    --region "${AWS_REGION}" || true

  info "State backends deleted."
else
  info "Step 4/4 — Skipping state deletion (use --nuke-state to also remove S3/DynamoDB)"
  info "State bucket:  s3://${TF_STATE_BUCKET}"
  info "Kops bucket:   ${KOPS_STATE_STORE}"
  info "Lock table:    ${TF_LOCK_TABLE}"
fi

# ─── Final verification ───────────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════════"
info " Destruction complete. Verifying cleanup..."
info "═══════════════════════════════════════════════"

# Check for orphaned EC2 instances tagged with this cluster
ORPHAN_COUNT=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || echo "unknown")

if [[ "$ORPHAN_COUNT" == "0" ]]; then
  info "✓ No orphaned EC2 instances found"
elif [[ "$ORPHAN_COUNT" == "unknown" ]]; then
  warn "Could not check for orphaned instances — verify manually"
else
  warn "⚠ ${ORPHAN_COUNT} EC2 instance(s) still tagged with this cluster — check AWS console"
fi

# Check for orphaned EBS volumes
ORPHAN_VOL_COUNT=$(aws ec2 describe-volumes \
  --filters \
    "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    "Name=status,Values=available" \
  --query 'length(Volumes[])' \
  --output text \
  --region "${AWS_REGION}" 2>/dev/null || echo "unknown")

if [[ "$ORPHAN_VOL_COUNT" == "0" ]]; then
  info "✓ No orphaned EBS volumes found"
else
  warn "⚠ ${ORPHAN_VOL_COUNT} EBS volume(s) still tagged with this cluster — delete manually to avoid charges"
  aws ec2 describe-volumes \
    --filters \
      "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
      "Name=status,Values=available" \
    --query 'Volumes[].{ID:VolumeId,Size:Size,AZ:AvailabilityZone}' \
    --output table \
    --region "${AWS_REGION}"
fi

echo ""
info "Destroy script finished."
info "Remember to: cancel any AWS budget alerts, remove DNS NS records at your registrar,"
info "and archive this repository if you no longer need it."