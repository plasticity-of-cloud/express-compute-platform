# k3s-Xpress: VPC CNI + Karpenter Support

**Status:** Approved for GA (revised from "post-GA stretch goal")  
**Rationale:** k3s + VPC CNI + Karpenter delivers the unique value proposition:
single-binary simplicity (~2 min boot, 300MB overhead) with enterprise
networking and autoscaling — lighter than EKS-D, more capable than stock k3s.

---

## 1. Why VPC CNI Works on k3s

The AWS VPC CNI is architecture-agnostic. It doesn't care what bootstrapped
the API server — it's a DaemonSet + CNI binary that talks to the EC2 API.

**What VPC CNI needs from the host:**

| Requirement | k3s provides? |
|-------------|---------------|
| Running kubelet | ✓ (embedded in k3s) |
| `/etc/cni/net.d/` directory | ✓ (k3s creates it) |
| Empty CNI config (no competing CNI) | ✓ (`--flannel-backend=none`) |
| Instance metadata (IMDS) | ✓ (EC2, same as EKS-D) |
| IAM permissions for ENI ops | ✓ (instance profile) |
| CNI binaries in `/opt/cni/bin/` | ✓ (pre-baked in AMI) |

**What k3s needs to enable external CNI:**

```yaml
# /etc/rancher/k3s/config.yaml
flannel-backend: "none"
disable-network-policy: true
```

That's it. k3s skips Flannel, leaves `/etc/cni/net.d/` empty, and nodes stay
`NotReady` until the VPC CNI DaemonSet installs its config. This is exactly
the same pattern as a kubeadm cluster with `--pod-network-cidr` omitted.

---

## 2. CNI Configuration Modes

k3s-Xpress supports two CNI modes, selected at cluster creation time:

| Mode | Flag | Pod IPs | Use Case |
|------|------|---------|----------|
| `flannel` (default) | `--cni flannel` | Overlay (10.42.0.0/16) | Simple, no ENI limits, dev/edge |
| `vpc` | `--cni vpc` | VPC-native (from subnet) | Production, SecurityGroups for pods, direct pod addressing |

### Mode: Flannel (default)

```
ecp create-cluster my-k3s --distribution k3s --cni flannel
```

- Pods get IPs from 10.42.0.0/16 (VXLAN overlay)
- No ENI limits — unlimited pods per node
- NAT Gateway required for internet access
- Cannot use SecurityGroups for Pods

### Mode: VPC CNI

```
ecp create-cluster my-k3s --distribution k3s --cni vpc
```

- Pods get IPs from the VPC subnet (prefix delegation)
- Pod-to-pod traffic is direct (no overlay, no encapsulation)
- SecurityGroups for Pods supported
- ENI limits apply (prefix delegation helps: ~110 pods on t4g.medium)
- Same CNI version and config as EKS-D-Xpress

---

## 3. AMI Changes for VPC CNI Support

The k3s AMI must include VPC CNI artifacts regardless of the runtime mode
(the mode is chosen at boot time, not bake time):

### 3.1 Pre-baked artifacts (added to `install-k3s.sh`)

```bash
# VPC CNI manifest (same as EKS-D)
/opt/k3s-xpress/manifests/aws-vpc-cni.yaml

# CNI binaries (extracted from cni-init image)
/opt/cni/bin/aws-cni
/opt/cni/bin/aws-cni-support.sh
/opt/cni/bin/egress-cni
/opt/cni/bin/host-local
/opt/cni/bin/loopback
# ... (same set as EKS-D)

# VPC CNI container images (in airgap tarball)
602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni:v1.22.3
602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni-init:v1.22.3
```

### 3.2 k3s config changes at boot (VPC CNI mode)

When `CNI_MODE=vpc` is set in `cluster.env`:

```yaml
# /etc/rancher/k3s/config.yaml (VPC CNI mode)
flannel-backend: "none"
disable-network-policy: true
# Pod CIDR comes from VPC subnet, not cluster-cidr
# cluster-cidr is still needed for Service allocation
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
```

When `CNI_MODE=flannel` (default):

```yaml
# /etc/rancher/k3s/config.yaml (Flannel mode)
# flannel-backend defaults to "vxlan" — no override needed
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
```

---

## 4. Boot Sequence Changes

### Flannel mode (unchanged from current implementation)

1. Start k3s → Flannel auto-configures → nodes Ready immediately

### VPC CNI mode (new path in `setup-k3s-xpress.sh`)

1. Start k3s with `flannel-backend=none` → nodes NotReady (no CNI)
2. Disable ec2-net-utils policy-routes (same as EKS-D `08-install-cni.sh`)
3. Apply VPC CNI manifest from `/opt/k3s-xpress/manifests/aws-vpc-cni.yaml`
4. Wait for `aws-node` DaemonSet rollout → nodes become Ready
5. Continue with add-on installation

Time impact: adds ~15–20 seconds (same as EKS-D CNI install).

---

## 5. Karpenter on k3s

### 5.1 Why it works

Karpenter is a Kubernetes controller. It:
1. Watches for pending pods
2. Calls EC2 RunInstances with a launch template
3. Waits for the new node to join the cluster

The k3s API server is a **standard Kubernetes API server**. Worker kubelet
doesn't know or care that it was bootstrapped by k3s rather than kubeadm.
This means we can launch **EKS Optimized AMI** workers that join the k3s
control plane — exactly the same AMIs that EKS and EKS-D-Xpress use.

### 5.2 Worker authentication (aws-iam-authenticator)

Just like EKS-D-Xpress, the k3s API server is configured with
`authentication-token-webhook-config-file` pointing at the aws-iam-authenticator
webhook (localhost:21362). This must be set up **before** k3s starts.

The boot sequence:
1. `install-aws-iam-authenticator.sh` — writes config + webhook kubeconfig + auto-deploy manifest
2. k3s server starts with `kube-apiserver-arg: authentication-token-webhook-config-file=...`
3. aws-iam-authenticator Pod starts (via `/var/lib/rancher/k3s/server/manifests/`)
4. Workers authenticate their IAM role → mapped to `system:node:{{EC2PrivateDNSName}}`

This is the **same authentication model as EKS-D-Xpress**. Workers (including
EKS Optimized AMI nodes) present an IAM-signed token; the authenticator
validates it and returns the mapped Kubernetes identity.

### 5.3 Worker node join (EKS Optimized AMI + kubelet bootstrap)

Workers launched by Karpenter use **standard kubelet TLS bootstrapping** —
the same mechanism as kubeadm clusters and EKS:

1. Worker's user data configures kubelet to point at the k3s API server
2. Kubelet presents a bootstrap token (stored in SSM by the control plane)
3. API server issues a client certificate via CSR approval
4. Worker registers as a node in `system:nodes` group (via IAM authenticator)

**Critical insight:** The worker does NOT run `k3s agent`. It runs standard
kubelet from the EKS Optimized AMI. The k3s control plane is just a
Kubernetes API server — kubelet doesn't need k3s-specific anything.

### 5.4 Worker user data (for Karpenter EC2NodeClass)

```bash
#!/bin/bash
# User data for EKS Optimized AMI workers joining k3s control plane

CLUSTER_NAME="{{.ClusterName}}"
AWS_REGION="{{.Region}}"

# Fetch join credentials from SSM
API_SERVER=$(aws ssm get-parameter \
  --name "/express-compute/cluster/${CLUSTER_NAME}/k3s-url" \
  --query 'Parameter.Value' --output text --region ${AWS_REGION})

BOOTSTRAP_TOKEN=$(aws ssm get-parameter \
  --name "/express-compute/cluster/${CLUSTER_NAME}/bootstrap-token" \
  --with-decryption \
  --query 'Parameter.Value' --output text --region ${AWS_REGION})

# Write kubelet bootstrap kubeconfig
mkdir -p /etc/kubernetes
cat > /etc/kubernetes/bootstrap-kubelet.conf <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: ${API_SERVER}
      insecure-skip-tls-verify: true
users:
  - name: kubelet-bootstrap
    user:
      token: ${BOOTSTRAP_TOKEN}
contexts:
  - name: bootstrap
    context:
      cluster: k3s
      user: kubelet-bootstrap
current-context: bootstrap
EOF

# Configure kubelet (EKS Optimized AMI already has kubelet installed)
cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
  - 10.43.0.10
clusterDomain: cluster.local
authentication:
  webhook:
    enabled: true
authorization:
  mode: Webhook
serverTLSBootstrap: true
EOF

# Start kubelet with bootstrap
systemctl enable kubelet
systemctl start kubelet
```

### 5.5 Components installed on k3s server for Karpenter

| Component | Purpose | Same as EKS-D? |
|-----------|---------|----------------|
| aws-iam-authenticator | IAM → K8s identity for workers | ✓ identical |
| Karpenter | Node autoscaling controller | ✓ identical (settings.eksControlPlane=false) |
| ecp-karpenter-support | EC2NodeClass webhook + validation | ✓ identical |
| Bootstrap token + RBAC | Kubelet TLS bootstrap for workers | ✓ same mechanism |
| CSR auto-approver | Auto-approve worker node CSRs | ✓ same (kubelet-csr-approver) |

### 5.3 k3s-agent systemd unit (pre-baked in AMI)

```ini
[Unit]
Description=k3s agent
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s agent
Restart=always
RestartSec=5s
LimitNOFILE=1048576
Delegate=yes

[Install]
WantedBy=multi-user.target
```

### 5.6 SSM Parameters for Karpenter (published at boot by `install-karpenter.sh`)

| SSM Path | Type | Purpose |
|----------|------|---------|
| `/express-compute/cluster/{name}/k3s-url` | String | k3s API server URL (`https://<ip>:6443`) |
| `/express-compute/cluster/{name}/k3s-token` | SecureString | k3s node join token (for k3s agent fallback) |
| `/express-compute/cluster/{name}/bootstrap-token` | SecureString | Kubelet TLS bootstrap token (for EKS Optimized AMI workers) |

### 5.7 NodePool / EC2NodeClass for k3s with EKS Optimized AMI workers

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: k3s-workers
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "c", "m"]
  limits:
    cpu: "100"
    memory: "256Gi"
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: k3s-workers
spec:
  role: "express-compute-k3s-node"
  amiSelectorTerms:
    # Use EKS Optimized AMIs — same AMIs as EKS and EKS-D-Xpress workers
    - alias: "al2023@latest"
  subnetSelectorTerms:
    - tags:
        express-compute.io/subnet-type: "private"
  securityGroupSelectorTerms:
    - tags:
        express-compute.io/cluster: "${CLUSTER_NAME}"
  userData: |
    #!/bin/bash
    # EKS Optimized AMI worker joining k3s control plane
    CLUSTER_NAME="my-cluster"
    AWS_REGION="us-east-1"

    API_SERVER=$(aws ssm get-parameter \
      --name "/express-compute/cluster/${CLUSTER_NAME}/k3s-url" \
      --query 'Parameter.Value' --output text --region ${AWS_REGION})
    BOOTSTRAP_TOKEN=$(aws ssm get-parameter \
      --name "/express-compute/cluster/${CLUSTER_NAME}/bootstrap-token" \
      --with-decryption \
      --query 'Parameter.Value' --output text --region ${AWS_REGION})

    mkdir -p /etc/kubernetes
    cat > /etc/kubernetes/bootstrap-kubelet.conf <<EOF
    apiVersion: v1
    kind: Config
    clusters:
      - name: k3s
        cluster:
          server: ${API_SERVER}
          insecure-skip-tls-verify: true
    users:
      - name: kubelet-bootstrap
        user:
          token: ${BOOTSTRAP_TOKEN}
    contexts:
      - name: bootstrap
        context:
          cluster: k3s
          user: kubelet-bootstrap
    current-context: bootstrap
    EOF

    # Configure and start kubelet (already installed on EKS Optimized AMI)
    cat > /var/lib/kubelet/config.yaml <<EOF
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    clusterDNS: ["10.43.0.10"]
    clusterDomain: cluster.local
    authentication:
      webhook: {enabled: true}
    authorization:
      mode: Webhook
    serverTLSBootstrap: true
    EOF

    systemctl enable --now kubelet
```

### 5.8 Karpenter + VPC CNI interaction

When using VPC CNI mode with Karpenter:
- New worker nodes join with `flannel-backend=none` (inherited from server config)
- VPC CNI DaemonSet auto-deploys on the new node
- IPAMD allocates ENIs/prefixes → node becomes Ready
- Same flow as EKS-D worker nodes joining via Karpenter

---

## 6. CLI Flag Addition

```
ecp create-cluster my-k3s \
  --distribution k3s \
  --cni vpc \              # NEW: "flannel" (default) or "vpc"
  --autoscaling karpenter  # NEW: "none" (default) or "karpenter"
  --arch arm64 \
  --pricing spot \
  --wait
```

### Autoscaling modes

| Mode | Description |
|------|-------------|
| `none` (default) | Single-node, no worker scaling |
| `karpenter` | Karpenter manages worker fleet via EC2NodeClass |

When `--autoscaling karpenter`:
- Control plane stores the k3s server URL + token in SSM
- Karpenter is installed on the server node
- Worker AMI must be the same k3s-Xpress AMI (it contains both server and agent)

---

## 7. SSM Parameters (Additional for Karpenter)

Published by the **control plane** when `autoscaling=karpenter`:

| SSM Path | Written By | Value |
|----------|-----------|-------|
| `/express-compute/cluster/{name}/k3s-url` | TenantEc2Service | `https://<server-ip>:6443` |
| `/express-compute/cluster/{name}/k3s-token` | TenantEc2Service | Node join token (SecureString) |

The server extracts the token from `/var/lib/rancher/k3s/server/token` after
boot and pushes it to SSM (done by `setup-k3s-xpress.sh` as a post-boot step).

---

## 8. Revised Comparison Matrix

| Feature | k3s-Xpress (Flannel) | k3s-Xpress (VPC CNI) | EKS-D-Xpress |
|---------|---------------------|---------------------|-------------|
| Boot time | < 90s | < 2 min | < 4 min |
| Control plane overhead | ~300 MB | ~300 MB | ~1.5 GB |
| Min instance | c6g.large (4 GB) | c6g.large (4 GB) | c6g.large (4 GB) |
| Pod networking | Overlay (VXLAN) | VPC-native (ENI) | VPC-native (ENI) |
| Pod SecurityGroups | ✗ | ✓ | ✓ |
| Karpenter | ✓ | ✓ | ✓ |
| Max pods/node | Unlimited | ~110 (prefix delegation) | ~110 (prefix delegation) |
| EKS API compat | ✗ | ✗ | ✓ |
| Monthly cost (Spot) | ~$6 | ~$12 | ~$24 |

**The sweet spot:** k3s + VPC CNI + Karpenter gives you 90% of EKS at 50% of the cost
and 50% of the boot time.

---

## 9. Implementation Plan Updates

### Phase 1 additions (AMI builder)

- [ ] Pre-bake VPC CNI manifest + binaries in k3s AMI (reuse `vpc-cni.sh` logic)
- [ ] Pre-pull VPC CNI images into airgap tarball
- [ ] Pre-bake `k3s-agent.service` systemd unit for worker nodes
- [ ] Add Karpenter chart to pre-cached charts

### Phase 2 additions (boot scripts)

- [ ] `setup-k3s-xpress.sh`: read `CNI_MODE` from cluster.env, branch config
- [ ] New: `cluster-setup/k3s/install-vpc-cni.sh` (adapted from `08-install-cni.sh`)
- [ ] New: `cluster-setup/k3s/install-karpenter.sh` (k3s-specific user data template)
- [ ] Post-boot: push k3s token to SSM (for Karpenter worker join)

### Phase 3 additions (control plane)

- [ ] `--cni` flag: `flannel` | `vpc`
- [ ] `--autoscaling` flag: `none` | `karpenter`
- [ ] cluster.env: add `CNI_MODE`, `AUTOSCALING_MODE`
- [ ] SSM: publish k3s-url and k3s-token when Karpenter enabled
- [ ] EC2NodeClass template generation with k3s agent user data

---

## 10. Risks & Mitigations (Revised)

| Risk | Impact | Mitigation |
|------|--------|-----------|
| VPC CNI version incompatibility with k3s embedded kubelet | Medium | Same kubelet API — version alignment is at CRI level, not control plane |
| IPAMD startup race (node NotReady before ENIs attached) | Low | Same pattern as EKS-D, proven stable |
| Karpenter worker join latency (SSM token fetch) | Low | Token cached; <5s additional boot time |
| k3s token rotation breaks Karpenter workers | Medium | Token is stable across restarts; rotation is manual |
| Larger AMI from VPC CNI + Flannel co-bundled | Low | ~200MB addition; still well under 2GB target |
