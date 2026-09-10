# k3s-Xpress Component Versions

Pinned versions from the official [k3s release notes](https://docs.k3s.io/release-notes/v1.35.X). Both 1.35 and 1.36 tracks are supported.

## Version Matrix

| Component | k3s 1.35 (`v1.35.7+k3s1`) | k3s 1.36 (`v1.36.3+k3s1`) |
|-----------|---------------------------|---------------------------|
| **k3s** | v1.35.7+k3s1 | v1.36.3+k3s1 |
| **Kubernetes** | v1.35.7 | v1.36.3 |
| **etcd (embedded)** | v3.6.14-k3s1 | v3.6.14-k3s1 |
| **containerd** | v2.2.5-k3s2 | v2.3.2-k3s2 |
| **runc** | v1.4.2 | v1.4.2 |
| **flannel** | v0.28.4 (disabled) | v0.28.4 (disabled) |
| **kine (SQLite)** | v0.16.3 | v0.16.3 |
| **SQLite** | 3.53.2 | 3.53.2 |
| **coredns** | v1.14.6 | v1.14.6 |
| **metrics-server** | v0.9.0 | v0.9.0 |
| **local-path-provisioner** | v0.0.36 | v0.0.36 |
| **helm-controller** | v0.17.7 | v0.17.7 |
| **traefik** | **disabled** | **disabled** |
| **servicelb** | **disabled** | **disabled** |

## Add-On Versions (shared across k3s 1.35/1.36)

| Component | Version | Source |
|-----------|---------|--------|
| cert-manager | v1.20.2 | quay.io/jetstack |
| CloudWatch Agent | v1.300048.1 | public.ecr.aws/cloudwatch-agent |
| ECP Workload Identity | 1.1.6 | ghcr.io/codriverlabs |
| ecp CLI | 1.1.6 | ghcr.io/codriverlabs |
| ECR credential provider | (shared with EKS-D) | — |
| syft | 1.22.0 | github.com/anchore/syft |

## k3s vs EKS-D Comparison

| Aspect | EKS-D-Xpress | k3s-Xpress |
|--------|-------------|------------|
| Control plane | kubeadm + separate etcd | k3s server (embedded) |
| Datastore | etcd (standalone, 20 GB EBS) | SQLite (2 GB EBS) |
| CNI | AWS VPC CNI | AWS VPC CNI |
| Autoscaling | Karpenter | Karpenter |
| Binaries | ~12 (kubeadm, kubelet, kubectl, etcd, etc.) | 1 (k3s) + kubectl symlink |
| Boot time target | < 4 min | < 2 min |
| Image size | ~3.5 GB | ~2 GB |
| Cost profile | Same instance class (full add-on stack) | Same instance class (full add-on stack) |

## Disabled k3s Components

The following bundled k3s components are disabled at boot:

- **traefik** — replaced by AWS Load Balancer Controller or direct NLB/ALB
- **servicelb** — replaced by AWS Cloud Controller Manager for LoadBalancer services
- **flannel** — replaced by AWS VPC CNI (`flannel-backend: "none"`)

## Release Notes

- Both v1.35.7+k3s1 and v1.36.3+k3s1 released Aug 04, 2026
- These are the latest stable releases in each track
- k3s embeds containerd, runc, flannel (disabled), CoreDNS, metrics-server, and local-path-provisioner

## Verification

```bash
# Check k3s release
curl -s https://api.github.com/repos/k3s-io/k3s/releases | \
  jq '.[] | select(.tag_name | startswith("v1.35")) | .tag_name' | head -3

# Check installed version on a running cluster
k3s --version
kubectl version --short
```

## References

- [k3s v1.35.X Release Notes](https://docs.k3s.io/release-notes/v1.35.X)
- [k3s v1.36.X Release Notes](https://docs.k3s.io/release-notes/v1.36.X)
- [k3s Releases](https://github.com/k3s-io/k3s/releases)
- [k3s Documentation](https://docs.k3s.io/)
- [k3s Airgap Installation](https://docs.k3s.io/installation/airgap)
