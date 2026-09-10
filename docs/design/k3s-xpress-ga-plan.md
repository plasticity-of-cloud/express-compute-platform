# k3s-Xpress GA — Feature Plan

**Branch:** `feature/k3s-xpress-ga`  
**Target:** General Availability (v1.0.0) of k3s-Xpress — Golden AMI + managed cluster lifecycle  
**Date:** August 2026  

---

## 1. Vision

k3s-Xpress delivers production-ready k3s clusters on AWS with the same golden AMI
strategy as EKS-D-Xpress: sub-3-minute boot, zero runtime downloads, full Workload
Identity support, and the same `ecp` CLI lifecycle.

**Key proposition:** Lighter, faster, cheaper than EKS-D-Xpress — ideal for
dev/staging, edge, single-node, and cost-sensitive production workloads.

---

## 2. Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                      k3s-Xpress AMI                             │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Pre-baked:                                                    │
│  ├── k3s binary (server + agent)                               │
│  ├── containerd (k3s embedded)                                 │
│  ├── Container images (airgap tarball)                         │
│  │   ├── coredns, metrics-server, local-path-provisioner       │
│  │   ├── traefik (optional, disabled by default)               │
│  │   ├── cert-manager                                          │
│  │   ├── cloudwatch-agent                                      │
│  │   └── ecp-workload-identity components                      │
│  ├── Helm charts (cached in /opt/k3s-xpress/charts/)           │
│  ├── ECR credential provider                                   │
│  ├── ecp CLI                                                   │
│  └── ecp-boot.service (systemd boot orchestrator)              │
│                                                                │
│  Boot-time only:                                               │
│  ├── k3s server start (single command)                         │
│  ├── Install add-ons from local charts                         │
│  └── Register cluster with ECP control plane                   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### k3s vs EKS-D Comparison

| Aspect | EKS-D-Xpress | k3s-Xpress |
|--------|-------------|------------|
| Control plane | kubeadm + separate etcd | k3s server (embedded) |
| Datastore | etcd (standalone) | SQLite (single) / embedded etcd (HA) |
| CNI | AWS VPC CNI | Flannel (default) or Cilium |
| Binaries | ~12 (kubeadm, kubelet, kubectl, etcd, etc.) | 1 (k3s) + kubectl symlink |
| Boot time target | < 4 min | < 2 min |
| Worker join | kubeadm join + node bootstrap | k3s agent + token |
| Certificate mgmt | kubeadm certs | k3s auto-rotation |
| Image size | ~3.5 GB | ~2 GB |
| Cost profile | Larger instances (control plane overhead) | t4g.small viable |

---

## 3. Scope — GA Requirements

### 3.1 Golden AMI (Packer)

- [ ] New Packer template: `ami-builder/k3s-xpress.pkr.hcl`
- [ ] Dual-arch builds: arm64 (Graviton) + x86_64
- [ ] Base: AL2023 (same as EKS-D variant)
- [ ] Pre-installed k3s binary (pinned version)
- [ ] Airgap image tarball (k3s images + add-on images)
- [ ] ECR credential provider configured
- [ ] Helm charts cached locally
- [ ] AMI signing (same KMS key as EKS-D variant)
- [ ] SBOM generation (SPDX 2.3)
- [ ] SSM parameter publishing (`/express-compute/infra/ami/k3s/{arch}/{version}`)

### 3.2 Cluster Boot (setup scripts)

- [ ] `cluster-setup/k3s/setup-k3s-xpress.sh` — master orchestrator
- [ ] Server bootstrap (single-node default, HA optional)
- [ ] Wait for k3s readiness
- [ ] Install add-ons from local Helm charts:
  - cert-manager
  - ECP Workload Identity (auth-proxy + webhook + pod-identity-agent)
  - CloudWatch agent
  - metrics-server (if not using k3s built-in)
- [ ] Register with ECP control plane
- [ ] Karpenter agent pool support (stretch goal for GA)
- [ ] Progress reporting (same `progress.sh` pattern)

### 3.3 CLI Integration

- [ ] `ecp create-cluster my-k3s --distribution k3s --arch arm64 --wait`
- [ ] `ecp delete-cluster my-k3s`
- [ ] `ecp get-cluster-access my-k3s` (kubeconfig retrieval)
- [ ] `ecp describe-cluster my-k3s` (shows k3s version, node count, status)
- [ ] `ecp stop-cluster / resume-cluster` (same lifecycle as EKS-D)

### 3.4 Networking

- [ ] Default: Flannel VXLAN (simplest, works everywhere)
- [ ] Optional: Cilium (for network policy + eBPF)
- [ ] Pod-to-AWS-service connectivity via NAT Gateway (standard VPC)
- [ ] No VPC CNI (k3s doesn't use ENI-based pod networking)
- [ ] Service type LoadBalancer via AWS Cloud Controller Manager or ServiceLB

### 3.5 Storage

- [ ] Default: local-path-provisioner (k3s built-in)
- [ ] Optional: EBS CSI driver (for persistent volumes)
- [ ] Pre-pulled EBS CSI images in airgap tarball

### 3.6 CI/CD

- [ ] GitHub Actions workflow: `k3s-release.yml`
- [ ] Reuse existing OIDC IAM trust (same CDK stack)
- [ ] Separate AMI naming: `k3s-xpress-{arch}-{version}`
- [ ] Separate SSM parameters: `/express-compute/infra/ami/k3s/{arch}/{k3s-version}`

### 3.7 UAT (Robot Framework)

- [ ] k3s cluster lifecycle test (create → verify → delete)
- [ ] Workload Identity test (same pattern as EKS-D UAT)
- [ ] Boot time assertion (< 2 min target)

---

## 4. Component Versions

Aligned with the EKS-D version matrix (1.35 / 1.36).

### Version Matrix

| Component | k3s 1.35 | k3s 1.36 |
|-----------|----------|----------|
| **k3s** | v1.35.7+k3s1 | v1.36.3+k3s1 |
| **Kubernetes** | v1.35.7 | v1.36.3 |
| **etcd (embedded)** | v3.6.14-k3s1 | v3.6.14-k3s1 |
| **containerd** | v2.4.x (embedded) | v2.4.x (embedded) |
| **runc** | v1.4.2 | v1.4.2 |
| **flannel** | v0.28.4 | v0.28.4 |
| **coredns** | v1.14.6 | v1.14.6 |
| **metrics-server** | v0.9.0 | v0.9.0 |
| **local-path-provisioner** | v0.0.36 | v0.0.36 |
| **helm-controller** | v0.17.7 | v0.17.7 |
| **kine (SQLite)** | v0.16.3 | v0.16.3 |
| **traefik** | **disabled** | **disabled** |
| **servicelb** | **disabled** | **disabled** |

### Add-On Versions (shared across k3s 1.35/1.36)

| Component | Version | Source |
|-----------|---------|--------|
| cert-manager | v1.20.2 | quay.io/jetstack |
| CloudWatch Agent | v1.300048.1 | public.ecr.aws/cloudwatch-agent |
| ECP Workload Identity | 1.1.6 | ghcr.io/codriverlabs |
| ecp CLI | 1.1.6 | ghcr.io/codriverlabs |
| ECR credential provider | (shared with EKS-D) | — |
| syft | 1.22.0 | github.com/anchore/syft |

> **Release dates:** Both v1.35.7+k3s1 and v1.36.3+k3s1 released Aug 04, 2026.
> These are the latest stable releases in each track.

---

## 5. Directory Structure (New Files)

```
express-compute-platform/
├── ami-builder/
│   ├── k3s-xpress.pkr.hcl              # NEW — k3s Packer template
│   ├── scripts/
│   │   ├── k3s/                         # NEW — k3s-specific scripts
│   │   │   ├── install-k3s.sh           #   Main AMI provisioner
│   │   │   ├── airgap-images.sh         #   Build airgap tarball
│   │   │   └── component-versions.env   #   k3s version pins
│   │   └── (shared scripts unchanged)
│   └── build-k3s-amis.sh               # NEW — k3s build orchestrator
├── cluster-setup/
│   └── k3s/                             # NEW — k3s boot scripts
│       ├── setup-k3s-xpress.sh          #   Master orchestrator
│       ├── install-addons.sh            #   Add-on installation
│       └── config.yaml                  #   k3s server config template
├── docs/
│   └── user-guides/
│       └── k3s-xpress.md               # NEW — k3s user guide
├── .github/workflows/
│   └── k3s-release.yml                  # NEW — k3s CI/CD
└── K3S_COMPONENT_VERSIONS.md            # NEW — k3s version matrix
```

---

## 6. Implementation Phases

### Phase 1: Foundation (Days 1–3)

1. Create Packer template (`k3s-xpress.pkr.hcl`)
   - Fork from `ecp-golden-ami.pkr.hcl`, strip EKS-D specifics
   - Same dual-arch, same AL2023 base, same signing/SBOM
2. Write `install-k3s.sh` — the AMI provisioner
   - Install k3s binary (airgap mode)
   - Pre-pull all images into airgap tarball
   - Configure ECR credential provider
   - Stage Helm charts and boot scripts
3. First successful AMI build (arm64 initially)

### Phase 2: Boot & Lifecycle (Days 4–6)

4. Write `setup-k3s-xpress.sh` — the boot orchestrator
   - Start k3s server with pre-configured settings
   - Wait for API server readiness
   - Install add-ons (cert-manager, WI, CloudWatch)
   - Register with ECP control plane
5. End-to-end boot test: AMI → running cluster with `kubectl get nodes`
6. Integrate with `ecp create-cluster --distribution k3s`

### Phase 3: Add-Ons & Identity (Days 7–9)

7. Workload Identity on k3s
   - Validate cert-manager + auth-proxy + webhook + pod-identity-agent
   - Test `ecp create-association` → pod gets credentials
8. CloudWatch agent integration
9. EBS CSI (optional add-on)

### Phase 4: CI/CD & UAT (Days 10–12)

10. GitHub Actions workflow (`k3s-release.yml`)
11. Robot Framework UAT suite for k3s
12. Documentation: user guide, component versions, architecture

### Phase 5: GA Polish (Days 13–15)

13. Boot time optimization (target < 2 min)
14. HA mode (3-node embedded etcd) — stretch
15. Security review, cost estimation update
16. Tag: `v1.0.0-k3s-rc1`

---

## 7. Design Decisions

### 7.1 Separate Packer Template (not parameterized)

The EKS-D and k3s install paths are fundamentally different enough that
sharing a single Packer template with conditionals would add complexity
without benefit. Shared scripts (signing, SBOM, ECR auth) are called
from both templates.

### 7.2 Airgap Mode (not pull-through cache at boot)

k3s natively supports airgap via `/var/lib/rancher/k3s/agent/images/`.
We pre-build a tarball during AMI bake and k3s loads it at startup.
This is simpler and faster than the EKS-D approach of pre-pulling into
containerd's content store.

### 7.3 Flannel Default (not VPC CNI)

k3s ships with Flannel. Using VPC CNI would require disabling k3s's
built-in CNI and managing ENIs separately — losing much of k3s's
simplicity. For workloads that need VPC-native pod IPs, recommend
EKS-D-Xpress instead.

### 7.4 No Karpenter at GA (ASG-based scaling)

Karpenter assumes EKS-D or EKS for node provisioning. k3s agent nodes
join differently (token-based). For GA, we use ASG-based scaling with
k3s agent launch templates. Karpenter support is a post-GA enhancement.

### 7.5 Single Binary Advantage

k3s ships as one binary with embedded containerd, flannel, CoreDNS,
local-path-provisioner, and metrics-server. This dramatically simplifies
the install script compared to EKS-D's multi-binary approach.

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| k3s version incompatibility with ECP WI | High | Test WI on k3s early (Phase 1) |
| Airgap tarball too large (>2GB) | Medium | Strip traefik, only include essentials |
| Boot time regression from add-on installs | Medium | Parallel helm installs, pre-rendered manifests |
| ECR credential provider conflicts with k3s embedded containerd | Medium | Test early, k3s supports custom credential providers |
| ASG scaling slower than Karpenter | Low | Acceptable for GA, Karpenter planned post-GA |

---

## 9. Success Criteria

- [ ] `ecp create-cluster my-k3s --distribution k3s --arch arm64 --wait` boots in < 2 minutes
- [ ] Workload Identity works identically to EKS-D variant
- [ ] Golden AMI is signed and verifiable offline
- [ ] SBOM generated for every build
- [ ] UAT passes: lifecycle + workload identity + boot time
- [ ] Cost: single-node k3s on t4g.small is viable (~$12/month Spot)
- [ ] Documentation complete: user guide + component versions

---

## 10. Out of Scope (Post-GA)

- Karpenter integration for k3s agent pools
- HA mode with external datastore (PostgreSQL/MySQL)
- Cilium CNI option
- Multi-server HA with embedded etcd (3-node)
- Rancher integration
- microk8s variant (separate feature branch)
