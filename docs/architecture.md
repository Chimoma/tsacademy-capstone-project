# TaskApp — Architecture Documentation

> **Stack**: React (Vite) · Flask · PostgreSQL · Kubernetes (Kops) · Terraform · AWS

---

## 1. System Architecture Diagram

```
                          INTERNET
                             │
                    ┌────────▼────────┐
                    │   Route 53      │
                    │  cynthia-devops.com │
                    │  (NS delegation)│
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   AWS ALB /     │
                    │  NLB (public)   │
                    │  NGINX Ingress  │
                    │  + cert-manager │
                    │  (Let's Encrypt)│
                    └──────┬──┬───────┘
               HTTPS /     │  │    HTTPS /api
          ┌────────────────┘  └─────────────────┐
          │                                      │
┌─────────▼──────────────────────────────────────▼──────────┐
│                   VPC: 10.0.0.0/16                         │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            PUBLIC SUBNETS (NAT / LB only)            │  │
│  │                                                      │  │
│  │  us-east-1a          us-east-1b        us-east-1c    │  │
│  │  10.0.0.0/24         10.0.1.0/24       10.0.2.0/24  │  │
│  │  [NAT-GW-A]          [NAT-GW-B]        [NAT-GW-C]   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            PRIVATE SUBNETS (all cluster nodes)       │  │
│  │                                                      │  │
│  │  us-east-1a          us-east-1b        us-east-1c   │  │
│  │  10.0.10.0/24        10.0.11.0/24      10.0.12.0/24 │  │
│  │                                                      │  │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐       │  │
│  │  │ Master-1 │    │ Master-2 │    │ Master-3 │       │  │
│  │  │(t3.medium│    │(t3.medium│    │(t3.medium│       │  │
│  │  │  + etcd) │    │  + etcd) │    │  + etcd) │       │  │
│  │  └──────────┘    └──────────┘    └──────────┘       │  │
│  │                                                      │  │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐       │  │
│  │  │ Worker-1 │    │ Worker-2 │    │ Worker-3 │       │  │
│  │  │(t3.large)│    │(t3.large)│    │(t3.large)│       │  │
│  │  └────┬─────┘    └────┬─────┘    └────┬─────┘       │  │
│  │       │               │               │              │  │
│  │  ┌────▼───────────────▼───────────────▼──────────┐   │  │
│  │  │           KUBERNETES WORKLOADS                 │   │  │
│  │  │                                                │   │  │
│  │  │  ┌──────────────┐  ┌──────────────┐           │   │  │
│  │  │  │  frontend    │  │  frontend    │  (2 pods) │   │  │
│  │  │  │  (React/Nginx│  │  (React/Nginx│           │   │  │
│  │  │  │  Deployment) │  │  Deployment) │           │   │  │
│  │  │  └──────────────┘  └──────────────┘           │   │  │
│  │  │                                                │   │  │
│  │  │  ┌──────────────┐  ┌──────────────┐           │   │  │
│  │  │  │  backend     │  │  backend     │  (2 pods) │   │  │
│  │  │  │  (Flask API) │  │  (Flask API) │           │   │  │
│  │  │  │  526Mi mem   │  │  526Mi mem   │           │   │  │
│  │  │  └──────┬───────┘  └──────┬───────┘           │   │  │
│  │  │         └────────┬────────┘                   │   │  │
│  │  │                  │                             │   │  │
│  │  │         ┌────────▼────────┐                   │   │  │
│  │  │         │   PostgreSQL    │  (StatefulSet)    │   │  │
│  │  │         │   (StatefulSet) │                   │   │  │
│  │  │         │  ┌─────────────┐│                   │   │  │
│  │  │         │  │ EBS gp3 PVC ││  (encrypted)      │   │  │
│  │  │         │  └─────────────┘│                   │   │  │
│  │  │         └─────────────────┘                   │   │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  SUPPORTING AWS SERVICES                            │   │
│  │                                                     │   │
│  │  S3 (kops state)   S3 (etcd backup)   DynamoDB      │   │
│  │  S3 (tf state)     (tf state lock)    KMS (EBS key) │   │
│  └─────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
```

---

## 2. CIDR Allocation & Justification

### VPC: `10.0.0.0/16`

A `/16` was chosen because it provides **65,536 usable IP addresses**, enough to accommodate:
- The current workload (6 nodes + ~50 pods)
- Horizontal scaling to ~500 nodes without renumbering
- Kubernetes pod CIDR (`100.96.0.0/11`) and service CIDR (`100.64.0.0/13`) are internal to Kops and don't consume VPC space

Choosing RFC 1918 `10.0.0.0/16` avoids conflicts with corporate VPNs that typically use `192.168.0.0/16` or `172.16.0.0/12`, making future VPC peering or Direct Connect simpler.

### Subnet Breakdown

| Subnet | CIDR | Size | Purpose |
|---|---|---|---|
| Public AZ-a | `10.0.0.0/24` | 256 IPs | NAT-GW-A, ALB ENI |
| Public AZ-b | `10.0.1.0/24` | 256 IPs | NAT-GW-B, ALB ENI |
| Public AZ-c | `10.0.2.0/24` | 256 IPs | NAT-GW-C, ALB ENI |
| Private AZ-a | `10.0.10.0/24` | 256 IPs | Masters, Workers (AZ-a) |
| Private AZ-b | `10.0.11.0/24` | 256 IPs | Masters, Workers (AZ-b) |
| Private AZ-c | `10.0.12.0/24` | 256 IPs | Masters, Workers (AZ-c) |

**Why `/24` per subnet?** Each private subnet needs to hold:
- 1 master node (Kops secondary ENI can attach up to 17 IPs on t3.medium)
- 1–3 worker nodes (Kops assigns a pod IP range per node)
- Each `t3.large` node can hold up to 35 pod IPs via the AWS VPC CNI
- `/24` gives 254 usable IPs per AZ — sufficient for ~7 nodes × 35 pods = 245 IPs worst case

Public subnets intentionally use small `/24` blocks because they hold no compute — only NAT Gateway ENIs and load balancer ENIs.

### Address Space Reserved for Growth

| Purpose | CIDR |
|---|---|
| Current use | `10.0.0.0/20` |
| Future environments (staging) | `10.0.16.0/20` |
| Future VPC peering / RDS subnet | `10.0.32.0/20` |
| Unallocated headroom | `10.0.48.0/12` → `10.255.0.0/16` |

---

## 3. High Availability Strategy

### 3.1 Control Plane HA

Kops provisions **3 master nodes** (one per AZ), each running:
- `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`
- A local `etcd` member

**etcd quorum**: With 3 members, the cluster tolerates **1 master failure** while maintaining write quorum (`⌊3/2⌋ + 1 = 2` members needed). The cluster continues to serve reads and writes as long as 2 of 3 masters are healthy.

**Automated etcd backups** run daily to S3 via a CronJob, providing a recovery point objective (RPO) of 24 hours. Snapshots use the `etcd-backup` Kops addon.

### 3.2 Worker Node HA

Worker nodes are distributed across 3 AZs using an **Instance Group** with `minSize: 3`, `maxSize: 9`. The Cluster Autoscaler (deployed as a Deployment with a single replica + leader election) scales nodes in response to pending pod pressure.

Kubernetes schedules frontend and backend pods using a **pod anti-affinity rule**:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: topology.kubernetes.io/zone
```

This guarantees no two replicas of the same deployment land in the same AZ.

### 3.3 Ingress HA

The NGINX Ingress Controller runs as a **DaemonSet** (one pod per worker node), fronted by an AWS Network Load Balancer (NLB) with cross-zone load balancing enabled. The NLB health-checks each node on port 80/443 and automatically routes around unhealthy nodes.

### 3.4 Database HA

PostgreSQL runs as a **StatefulSet** with a single replica backed by an EBS `gp3` volume (`Retain` reclaim policy). Because EBS volumes are AZ-scoped, the pod is pinned to the AZ where its PVC was provisioned using a `nodeAffinity` rule.

> **Note**: For production-grade HA on the database layer, consider migrating to AWS RDS Multi-AZ (see bonus deliverable). The current single-pod approach means DB downtime during node failure until rescheduling completes (~60–90 s).

### 3.5 NAT Gateway HA

Three NAT Gateways are deployed, one per public subnet. Private route tables in each AZ route `0.0.0.0/0` to the NAT GW in the **same AZ**. This eliminates cross-AZ data transfer charges and removes the NAT Gateway as a single point of failure.

### 3.6 Failover Proof

| Failure Scenario | Impact | Recovery |
|---|---|---|
| 1 master node lost | API may stall for ~30 s while etcd elects new leader | Automatic; kops ASG replaces node |
| 1 worker node lost | Pods rescheduled to remaining workers | Automatic; ~60 s |
| Master + worker lost simultaneously | etcd quorum maintained (2/3 masters); pod count reduced | Automatic |
| Full AZ outage | API available (2/3 masters); 2/3 of pods remain | Automatic; ASG launches replacements |
| NAT GW failure in 1 AZ | Only nodes in that AZ lose egress | Automatic rerouting by route table |

---

## 4. Security Model

### Network Segmentation
- All Kubernetes nodes (masters and workers) live exclusively in **private subnets** — no node has a public IP address
- The only public-facing resource is the NLB fronting the NGINX ingress
- Security groups allow `443/tcp` and `80/tcp` inbound on the NLB only from `0.0.0.0/0`; all other inbound traffic is denied at the SG level
- Inter-node communication uses Calico NetworkPolicy to enforce namespace isolation

### IAM Least Privilege
- A dedicated `kops-admin` IAM user is used only for cluster creation; it is not used for day-to-day operations
- Each node type (master, worker) has a separate **instance profile** with only the permissions Kops requires (e.g., workers have `ec2:DescribeInstances` but not `ec2:CreateVolume`)
- Terraform runs under a separate `terraform-deployer` role with a permission boundary

### Secrets Management
- Database credentials are stored as **Sealed Secrets** (Bitnami controller) — the encrypted `SealedSecret` YAML is safe to commit to Git; only the in-cluster controller can decrypt it using a key stored in etcd
- No plaintext passwords appear in any manifest, ConfigMap, or environment variable definition
- EBS volumes are encrypted at rest using a customer-managed KMS key

### TLS / Certificate Management
- `cert-manager` (v1.14+) watches `Ingress` resources annotated with `cert-manager.io/cluster-issuer: letsencrypt-prod`
- Certificates are auto-renewed 30 days before expiry via ACME HTTP-01 challenge
- HTTP → HTTPS redirect is enforced at the NGINX ingress layer

---

## 5. Component Versions (Pinned)

| Component | Version |
|---|---|
| Kubernetes | 1.28.x |
| Kops | 1.28.x |
| Terraform | 1.7.x |
| NGINX Ingress | 1.10.x |
| cert-manager | 1.14.x |
| Calico CNI | 3.27.x |
| AWS EBS CSI Driver | 1.28.x |
| Cluster Autoscaler | 1.28.x |
| Sealed Secrets | 0.26.x |