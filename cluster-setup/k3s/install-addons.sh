#!/bin/bash
# install-addons.sh — Install k3s-Xpress add-ons from local Helm charts.
# Called by setup-k3s-xpress.sh after k3s + VPC CNI are ready.
#
# Install order matters:
#   1. cert-manager       — TLS certificate lifecycle (required by ECP WI webhooks)
#   2. ECP Workload Identity — pod-level IAM credentials (required by CloudWatch, EBS CSI)
#   3. CloudWatch agent   — observability (uses WI for AWS credentials)
#   4. EBS CSI Driver     — persistent volumes (uses WI for AWS credentials)
#   5. metrics-server     — verify k3s built-in is functional
#
# All charts are pre-cached in /opt/k3s-xpress/charts/ by the AMI builder.
# All images are pre-loaded via the airgap tarball.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source /opt/k3s-xpress/version.env
source /opt/k3s-xpress/cluster.env

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
CHARTS_DIR="/opt/k3s-xpress/charts"

# Get region from IMDS if not set
if [ -z "${AWS_REGION:-}" ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
fi

# ── 1. cert-manager ──────────────────────────────────────────────────────────
echo "  [1/5] Installing cert-manager ${CERT_MANAGER_VERSION}..."
CERT_CHART=$(ls "${CHARTS_DIR}"/cert-manager-*.tgz 2>/dev/null | head -1)
if [ -z "$CERT_CHART" ]; then
  echo "  Warning: cert-manager chart not found in ${CHARTS_DIR}"
else
  helm upgrade --install cert-manager "$CERT_CHART" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --timeout=60s

  # Wait for webhook readiness (required before ECP WI can install its own webhooks)
  kubectl wait --for=condition=available deployment/cert-manager-webhook \
    -n cert-manager --timeout=40s || {
    echo "  Warning: cert-manager-webhook not ready within timeout"
  }
  echo "  ✓ cert-manager installed"
fi

# ── 2. ECP Workload Identity ─────────────────────────────────────────────────
# Must be installed BEFORE CloudWatch and EBS CSI — those add-ons use
# ECP Workload Identity (EKS Pod Identity equivalent) for AWS credentials.
echo "  [2/5] Installing ECP Workload Identity..."
if [ -n "${ECP_ENDPOINT:-}" ] && [[ "${INSTALL_ECP:-false}" == "true" ]]; then
  export ECP_ENDPOINT CLUSTER_NAME AWS_REGION ECP_CONTROL_PLANE_VERSION
  export CHART_DIR="${CHARTS_DIR}"

  CANONICAL_SCRIPT="${SCRIPT_DIR}/install-ecp-workload-identity.sh"
  if [ -f "$CANONICAL_SCRIPT" ]; then
    bash "$CANONICAL_SCRIPT" --oidc-mode managed
    echo "  ✓ ECP Workload Identity installed"
  else
    # Fall back to the copy baked from the control plane release
    FALLBACK="/opt/k3s-xpress/cluster-setup/install-ecp-workload-identity.sh"
    if [ -f "$FALLBACK" ]; then
      bash "$FALLBACK" --oidc-mode managed
      echo "  ✓ ECP Workload Identity installed (fallback script)"
    else
      echo "  Warning: install-ecp-workload-identity.sh not found, skipping"
    fi
  fi
else
  echo "  Skipping ECP Workload Identity (ECP_ENDPOINT not set or INSTALL_ECP=false)"
fi

# ── 3. CloudWatch Observability ───────────────────────────────────────────────
echo "  [3/5] Installing CloudWatch Observability agent..."
CW_CHART=$(ls "${CHARTS_DIR}"/amazon-cloudwatch-observability-*.tgz 2>/dev/null | head -1)
if [ -z "$CW_CHART" ]; then
  echo "  Warning: CloudWatch chart not found in ${CHARTS_DIR}"
else
  helm upgrade --install amazon-cloudwatch-observability "$CW_CHART" \
    --namespace amazon-cloudwatch \
    --create-namespace \
    --set clusterName="${CLUSTER_NAME}" \
    --set region="${AWS_REGION}" \
    --set k8sMode=K8S \
    --set manager.applicationSignals.autoMonitor.restartPods=false \
    --set-json 'agent.config={"logs":{"metrics_collected":{"kubernetes":{"enhanced_container_insights":false,"kubelet_https_verify":false}}}}' \
    --timeout=60s

  echo "  ✓ CloudWatch helm release applied"
fi

# ── 4. EBS CSI Driver ─────────────────────────────────────────────────────────
echo "  [4/5] Installing EBS CSI Driver..."
bash "${SCRIPT_DIR}/install-ebs-csi.sh"

# ── 5. Metrics Server (verify k3s built-in is functional) ─────────────────────
echo "  [5/5] Verifying metrics-server..."
kubectl wait --for=condition=available deployment/metrics-server \
  -n kube-system --timeout=30s 2>/dev/null && {
  echo "  ✓ metrics-server ready (k3s built-in)"
} || {
  echo "  Note: metrics-server not yet ready, k3s will reconcile"
}

echo "  ✓ All add-ons installed"
