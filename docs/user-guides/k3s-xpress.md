# k3s-Xpress User Guide

k3s-Xpress delivers production-ready k3s clusters on AWS with a golden AMI
strategy: sub-2-minute boot, zero runtime downloads, full Workload Identity
support, and the same `ecp` CLI lifecycle as EKS-D-Xpress.

---

## Overview

k3s-Xpress is the lightweight alternative to EKS-D-Xpress. It uses k3s
(a CNCF-certified Kubernetes distribution) instead of EKS-D, trading the
full EKS compatibility for dramatically reduced complexity and cost.

**Best for:** dev/staging environments, edge deployments, single-node clusters,
CI runners, and cost-sensitive production workloads.

**Use EKS-D-Xpress instead when:** you need full EKS API compatibility,
VPC-native pod networking (ENI per pod), Karpenter autoscaling, or multi-AZ
HA control planes.

---

## Quick Start

### Create a k3s cluster

```bash
ecp create-cluster my-k3s \
  --distribution k3s \
  --arch arm64 \
  --pricing spot \
  --wait
```

### Access the cluster

```bash
ecp get-cluster-access my-k3s
kubectl get nodes
kubectl get pods -A
```

### Delete the cluster

```bash
ecp delete-cluster my-k3s
```

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                    k3s-Xpress Instance                          │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  /usr/local/bin/k3s          ← Single binary (server + agent)  │
│  /var/lib/rancher/k3s/       ← Data directory                  │
│  ├── agent/images/           ← Airgap tarballs (pre-loaded)    │
│  ├── server/db/              ← SQLite datastore                │
│  └── server/manifests/       ← Auto-deploy manifests           │
│                                                                │
│  /opt/k3s-xpress/            ← Express Compute additions       │
│  ├── charts/                 ← Pre-cached Helm charts          │
│  ├── cluster-setup/          ← Boot orchestration scripts      │
│  ├── version.env             ← Version pins                    │
│  └── cluster.env             ← Instance-specific config        │
│                                                                │
│  Add-ons (installed at boot):                                  │
│  ├── cert-manager            ← TLS certificate lifecycle       │
│  ├── CloudWatch agent        ← Logs + metrics                  │
│  ├── ECP Workload Identity   ← Pod-level IAM credentials       │
│  └── metrics-server          ← k3s built-in                    │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Boot Sequence (< 2 minutes target)

1. **Instance starts** — golden AMI with everything pre-installed
2. **k3s-xpress-boot.service** triggers `setup-k3s-xpress.sh`
3. **Resolve metadata** — Node IP, instance ID, region from IMDSv2
4. **Write config** — `/etc/rancher/k3s/config.yaml` with instance-specific values
5. **Start k3s** — single binary boots API server, etcd, scheduler, kubelet
6. **Wait for readiness** — CoreDNS, system pods
7. **Install add-ons** — cert-manager, CloudWatch, verify metrics-server
8. **Register with ECP** — Workload Identity integration
9. **Done** — cluster ready for workloads

---

## Networking

### Default: Flannel VXLAN

k3s ships with Flannel as the default CNI. Pod networking uses VXLAN overlay,
which means pods get IPs from the cluster-cidr range (10.42.0.0/16), not from
the VPC CIDR.

```
Pod CIDR:     10.42.0.0/16
Service CIDR: 10.43.0.0/16
Cluster DNS:  10.43.0.10
```

### Internet Access

Pods reach AWS services and the internet via the node's NAT Gateway (standard
VPC pattern). No VPC CNI is needed.

### Load Balancing

Since traefik and servicelb are disabled, use:
- **AWS Load Balancer Controller** for Ingress (ALB) and Service type LoadBalancer (NLB)
- **NodePort** for simple dev access

---

## Storage

### Default: local-path-provisioner

k3s includes `local-path-provisioner` which creates PersistentVolumes backed
by local node storage. Suitable for single-node and dev/staging.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
```

### Optional: EBS CSI Driver

For persistent volumes that survive node replacement:

```bash
# EBS CSI images are pre-loaded in the airgap tarball
helm upgrade --install aws-ebs-csi-driver /opt/k3s-xpress/charts/aws-ebs-csi-*.tgz \
  --namespace kube-system
```

---

## Workload Identity

k3s-Xpress supports the same ECP Workload Identity as EKS-D-Xpress. Pods
receive short-lived AWS credentials scoped to their ServiceAccount.

```bash
# Create an association (same as EKS-D)
ecp create-association my-k3s \
  --service-account my-ns/my-sa \
  --role-arn arn:aws:iam::123456789012:role/my-role
```

---

## Monitoring

CloudWatch agent is installed at boot, providing:
- Container logs → CloudWatch Logs
- Kubernetes metrics → CloudWatch Metrics
- Application Signals (optional)

Logs are available immediately after boot in the `/aws/k3s-xpress/<cluster-name>` log group.

---

## Building the Golden AMI

### Local build

```bash
cd ami-builder
./build-k3s-amis.sh
```

### CI/CD

Push a tag matching `k3s-v*` to trigger the `k3s-release.yml` workflow.

---

## Configuration Reference

### cluster.env (pre-seeded by ECP control plane)

```bash
TENANT_ID=tenant-abc123
CLUSTER_NAME=my-k3s-cluster
AWS_REGION=us-east-1
ECP_ENDPOINT=https://api.express-compute.example.com
PROGRESS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/...
```

### version.env (baked into AMI)

```bash
K3S_KUBERNETES_VERSION=1.35
K3S_VERSION=v1.35.7+k3s1
CERT_MANAGER_VERSION=v1.20.2
CLOUDWATCH_AGENT_VERSION=v1.300048.1
ECP_CONTROL_PLANE_VERSION=1.1.6
INSTALL_ECP=true
K3S_DISABLE=traefik,servicelb
```

---

## Cost Profile

| Instance | vCPU | RAM | Monthly (Spot) | Use Case |
|----------|------|-----|----------------|----------|
| c6g.medium | 1 | 2 GB | ~$10 | Flannel-only dev (no Karpenter/VPC CNI) |
| c6g.large | 2 | 4 GB | ~$20 | Default — full add-on stack |
| c6g.xlarge | 4 | 8 GB | ~$40 | Heavy workloads on server node |

k3s control plane overhead is ~300 MB, but the full add-on stack (Karpenter, ECP WI,
VPC CNI, CloudWatch, EBS CSI, cert-manager) requires ~2 GB. The `c6g.large` default
provides enough headroom for system components plus light server-node workloads.

---

## Comparison: k3s-Xpress vs EKS-D-Xpress

| Feature | k3s-Xpress | EKS-D-Xpress |
|---------|-----------|-------------|
| Boot time | < 2 min | < 4 min |
| Min instance | c6g.large (2 vCPU, 4GB) | c6g.large (2 vCPU, 4GB) |
| CNI | Flannel (overlay) | VPC CNI (ENI per pod) |
| Datastore | SQLite | etcd |
| Autoscaling | ASG-based | Karpenter |
| EKS API compat | No | Yes |
| Workload Identity | ✓ | ✓ |
| CloudWatch | ✓ | ✓ |
| Golden AMI | ✓ | ✓ |
| Monthly cost (Spot) | ~$6–24 | ~$24–60 |

---

## Troubleshooting

### Check k3s status

```bash
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

### Check boot progress

```bash
sudo journalctl -u k3s-xpress-boot.service
```

### Reset cluster

```bash
sudo /usr/local/bin/k3s-uninstall.sh
# Then re-run setup:
sudo bash /opt/k3s-xpress/cluster-setup/setup-k3s-xpress.sh
```

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| k3s won't start | Missing cluster.env | Ensure TenantEc2Service seeds /opt/k3s-xpress/cluster.env |
| Pods stuck Pending | Airgap images not loaded | Check /var/lib/rancher/k3s/agent/images/ |
| No internet from pods | NAT Gateway missing | Check VPC route tables |
| ECR pull fails | Credential provider not configured | Verify /var/lib/rancher/k3s/agent/etc/credential-provider-config.yaml |
