# k3s-Xpress — CLI & Control Plane Integration

This document describes the changes required in the **control plane repo**
(`express-compute-control-plane`) to support the k3s-Xpress distribution,
and the SSM parameter contract between this repository and the control plane.

---

## 1. SSM Parameter Contract

The `express-compute-platform` repo (this repo) publishes SSM parameters that
the control plane components consume at runtime. The k3s-Xpress distribution
adds a parallel set of parameters under the `/express-compute/infra/ami/k3s/` prefix.

### Parameters Published by This Repo

| SSM Path | Written By | Value | Purpose |
|----------|-----------|-------|---------|
| `/express-compute/infra/ami/{arch}/{k8s-version}` | EKS-D Packer build | AMI ID (e.g. `ami-0abc123`) | EKS-D AMI lookup for tenant provisioning |
| `/express-compute/infra/ami/{arch}/{k8s-version}/signature` | `sign-ami.sh` | Base64 KMS signature | EKS-D AMI attestation verification |
| `/express-compute/infra/ami/k3s/{arch}/{k8s-version}` | **k3s Packer build** | AMI ID (e.g. `ami-0def456`) | **k3s AMI lookup for tenant provisioning** |
| `/express-compute/infra/ami/k3s/{arch}/{k8s-version}/signature` | `sign-ami.sh` | Base64 KMS signature | **k3s AMI attestation verification** |
| `/express-compute/infra/kms/ami-signing-key-arn` | CDK stack | KMS key ARN | Shared signing key (both distributions) |
| `/express-compute/infra/network/vpc-id` | Infra CDK stack | VPC ID | Shared by both distributions |
| `/express-compute/infra/launch-template/{arch}/{pricing}` | Infra CDK stack | Launch template ID | EKS-D only (k3s uses own template) |
| `/express-compute/infra/launch-template/k3s/{arch}/{pricing}` | **Infra CDK stack** | Launch template ID | **k3s launch template** |
| `/express-compute/infra/network/nat-gateway-enabled` | Infra CDK stack | `true`/`false` | Shared by both distributions |

### Per-Cluster Parameters (published at boot when Karpenter enabled)

| SSM Path | Written By | Value | Purpose |
|----------|-----------|-------|---------|
| `/express-compute/cluster/{name}/k3s-url` | `install-karpenter.sh` | `https://<ip>:6443` | k3s API server URL for worker join |
| `/express-compute/cluster/{name}/k3s-token` | `install-karpenter.sh` | SecureString | k3s node join token (agent fallback) |
| `/express-compute/cluster/{name}/bootstrap-token` | `install-karpenter.sh` | SecureString | Kubelet TLS bootstrap token for EKS Optimized AMI workers |

### Parameter Naming Convention

```
/express-compute/infra/ami/{distribution}/{arch}/{k8s-version}
                            │              │      │
                            │              │      └── "1.35" or "1.36"
                            │              └── "arm64" or "x86_64"
                            └── omitted for EKS-D (legacy), "k3s" for k3s-Xpress
```

**Examples:**
```
# EKS-D (existing, unchanged)
/express-compute/infra/ami/arm64/1.35           → ami-0abc123def
/express-compute/infra/ami/arm64/1.35/signature → <base64 sig>
/express-compute/infra/ami/x86_64/1.35          → ami-0xyz789abc

# k3s-Xpress (new)
/express-compute/infra/ami/k3s/arm64/1.35           → ami-0def456ghi
/express-compute/infra/ami/k3s/arm64/1.35/signature → <base64 sig>
/express-compute/infra/ami/k3s/x86_64/1.35          → ami-0jkl012mno
```

---

## 2. CLI Changes Required (Control Plane Repo)

### 2.1 `ecp create-cluster`

Add `--distribution` flag to select cluster type.

```
ecp create-cluster <name> [flags]

Flags:
  --distribution string   Cluster distribution: "eks-d" (default) or "k3s"
  --arch string           Instance architecture: "arm64" (default) or "x86_64"
  --pricing string        Pricing model: "spot" (default) or "on-demand"
  --instance-type string  Override instance type (default: auto-select based on distribution)
  --ssh-cidr string       CIDR for SSH access (optional)
  --wait                  Wait for cluster to be ready before returning
```

**Behavioral changes:**
- When `--distribution k3s`:
  - AMI lookup reads from `/express-compute/infra/ami/k3s/{arch}/{version}` (not the EKS-D path)
  - Launch template from `/express-compute/infra/launch-template/k3s/{arch}/{pricing}`
  - Same add-on stack as EKS-D: VPC CNI, Karpenter, Workload Identity, CloudWatch, EBS CSI
  - User data writes to `/opt/k3s-xpress/cluster.env` (not `/opt/eks-d/cluster.env`)
  - Boot timeout: 120s (vs 240s for EKS-D)
  - No separate etcd EBS volume (uses 2 GB data volume for SQLite instead of 20 GB for etcd)
  - Progress queue dedup ID prefix: `k3s-` to avoid collisions

**New instance defaults by distribution:**

| Distribution | arm64 default | x86_64 default |
|-------------|---------------|----------------|
| eks-d | c6g.large | m7i.large |
| k3s | c6g.large | m7i.large |

### 2.2 `ecp delete-cluster`

No flag changes. The control plane must store the distribution type in the
tenant record so it knows which cleanup path to follow (no etcd volume
detach for k3s, different AMI deregistration path).

### 2.3 `ecp get-cluster-access`

No flag changes. The kubeconfig format differs slightly:
- **EKS-D:** API server on port 6443, uses `aws-iam-authenticator` exec plugin
- **k3s:** API server on port 6443, uses token-based auth or `aws-iam-authenticator` (if ECP WI is configured)

The control plane should store the auth method in the tenant record and
generate the appropriate kubeconfig.

### 2.4 `ecp describe-cluster`

Add distribution info to the output:

```
Name:           my-k3s
Distribution:   k3s
Status:         ready
Kubernetes:     v1.35.7
k3s:            v1.35.7+k3s1
Architecture:   arm64
Instance:       c6g.large
Pricing:        spot
Node IP:        10.0.1.42
Region:         us-east-1
Created:        2026-08-16T14:30:00Z
Boot time:      87s
```

### 2.5 `ecp stop-cluster` / `ecp resume-cluster`

Same lifecycle as EKS-D. The control plane stops/starts the EC2 instance.
On resume, the k3s service auto-starts via systemd (`k3s.service`), and
`k3s-xpress-boot.service` does NOT re-run (guarded by `.installation_complete`).

### 2.6 `ecp list-clusters`

Add `DISTRIBUTION` column:

```
NAME        DISTRIBUTION  STATUS  ARCH    PRICING  AGE
my-eks      eks-d         ready   arm64   spot     2d
my-k3s      k3s           ready   arm64   spot     1h
```

---

## 3. TenantEc2Service Changes

The `TenantEc2Service` Lambda (control plane) must be updated to handle
k3s provisioning:

### 3.1 AMI Resolution

```python
# Current (EKS-D only)
ssm_path = f"/express-compute/infra/ami/{arch}/{k8s_version}"

# New (distribution-aware)
if distribution == "k3s":
    ssm_path = f"/express-compute/infra/ami/k3s/{arch}/{k8s_version}"
else:
    ssm_path = f"/express-compute/infra/ami/{arch}/{k8s_version}"
```

### 3.2 User Data / cluster.env Seeding

For k3s clusters, the user data must write to `/opt/k3s-xpress/cluster.env`:

```bash
# k3s user data (written by TenantEc2Service Lambda)
cat > /opt/k3s-xpress/cluster.env <<'ENVEOF'
TENANT_ID=${tenant_id}
CLUSTER_NAME=${cluster_name}
AWS_REGION=${region}
ECP_ENDPOINT=${ecp_endpoint}
PROGRESS_QUEUE_URL=${progress_queue_url}
ENVEOF
```

Compare with EKS-D which writes to `/opt/eks-d/cluster.env`.

### 3.3 Instance Profile

k3s clusters need the same instance profile as EKS-D clusters (ECR pull,
CloudWatch, SSM) but do NOT need:
- EBS volume attach/detach permissions (no separate etcd volume)
- Additional ENI permissions (no VPC CNI)

A shared `express-compute-node` profile works, or a smaller `express-compute-k3s-node`
profile can be created for least-privilege.

### 3.4 Launch Template Differences

| Aspect | EKS-D | k3s |
|--------|-------|-----|
| Root volume | 20 GB gp3 | 15 GB gp3 |
| Additional volume | 10 GB gp3 (etcd) | None |
| Instance type | c6g.large+ | c6g.large+ |
| User data target | `/opt/eks-d/cluster.env` | `/opt/k3s-xpress/cluster.env` |
| Boot service | `ecp-boot.service` | `k3s-xpress-boot.service` |

### 3.5 Health Check / Readiness

The control plane polls the SQS progress queue for both distributions.
The message format is identical:

```json
{
  "tenantId": "tenant-abc123",
  "state": "ready",        // "booting" | "provisioning" | "registering" | "ready" | "failed"
  "phase": "Cluster ready",
  "progress": 100
}
```

Boot timeout should be **120s for k3s** (vs 240s for EKS-D).

---

## 4. Database/State Changes

The tenant record must store the distribution:

```json
{
  "tenantId": "tenant-abc123",
  "clusterId": "my-k3s",
  "distribution": "k3s",        // NEW — "eks-d" (default) | "k3s"
  "arch": "arm64",
  "instanceType": "c6g.large",
  "k8sVersion": "1.35",
  "status": "ready",
  "instanceId": "i-0abc123",
  "nodeIp": "10.0.1.42",
  "createdAt": "2026-08-16T14:30:00Z",
  "bootTimeSeconds": 87
}
```

---

## 5. Infra CDK Stack Changes

The shared infrastructure CDK stack (`bundle/cdk/`) needs:

### 5.1 k3s Launch Templates

New launch templates for k3s (smaller root volume, no etcd volume):

```
/express-compute/infra/launch-template/k3s/arm64/spot
/express-compute/infra/launch-template/k3s/arm64/on-demand
/express-compute/infra/launch-template/k3s/x86_64/spot
/express-compute/infra/launch-template/k3s/x86_64/on-demand
```

### 5.2 Security Group

k3s uses the same ports as EKS-D (6443 for API server, VPC CNI ports).
The existing security group works unchanged.

---

## 6. Migration Path

No migration needed — k3s-Xpress is additive. Existing EKS-D clusters
are unaffected. The control plane should default to `distribution=eks-d`
when the field is absent (backward compatibility).

---

## 7. API Versioning

If the control plane exposes a REST API, the distribution field should be
added to the cluster creation endpoint:

```
POST /v1/clusters
{
  "name": "my-k3s",
  "distribution": "k3s",   // optional, defaults to "eks-d"
  "arch": "arm64",
  "pricing": "spot"
}
```

The response includes distribution in cluster details:

```
GET /v1/clusters/my-k3s
{
  "name": "my-k3s",
  "distribution": "k3s",
  "status": "ready",
  "k8sVersion": "1.35.7",
  "distributionVersion": "v1.35.7+k3s1",
  ...
}
```
