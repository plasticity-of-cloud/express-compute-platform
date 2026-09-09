#!/bin/bash
set -e

# airgap-images.sh — Build the add-on airgap image tarball for k3s-Xpress.
# k3s core images (coredns, flannel, metrics-server, local-path-provisioner)
# are handled by the official k3s airgap tarball.
# This script pulls add-on images (cert-manager, CloudWatch, ECP) and
# saves them as a tarball that k3s loads at startup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/component-versions.env"

CHARTS_DIR="/opt/k3s-xpress/charts"
AIRGAP_DIR="/var/lib/rancher/k3s/agent/images"
EXTRACT_IMAGES_PY="/tmp/extract-images.py"

echo "  Building add-on airgap image list..."

IMAGE_LIST="/tmp/k3s-addon-images.txt"
> "${IMAGE_LIST}"

# cert-manager images
CERT_CHART=$(ls "${CHARTS_DIR}"/cert-manager-*.tgz 2>/dev/null | head -1)
if [ -n "$CERT_CHART" ]; then
  helm template cert-manager "$CERT_CHART" --set crds.enabled=true 2>/dev/null | \
    python3 "${EXTRACT_IMAGES_PY}" | sort -u >> "${IMAGE_LIST}"
fi

# CloudWatch images
CW_CHART=$(ls "${CHARTS_DIR}"/amazon-cloudwatch-observability-*.tgz 2>/dev/null | head -1)
if [ -n "$CW_CHART" ]; then
  helm template amazon-cloudwatch-observability "$CW_CHART" \
    --set clusterName=build --set region=us-east-1 2>/dev/null | \
    python3 "${EXTRACT_IMAGES_PY}" | \
    grep -Ev 'windows|nvidia|neuron|dcgm-exporter|kubekins-e2e' | sort -u >> "${IMAGE_LIST}"
fi

# EBS CSI images
EBS_CHART=$(ls "${CHARTS_DIR}"/aws-ebs-csi-driver-*.tgz 2>/dev/null | head -1)
if [ -n "$EBS_CHART" ]; then
  helm template aws-ebs-csi-driver "$EBS_CHART" 2>/dev/null | \
    python3 "${EXTRACT_IMAGES_PY}" | \
    grep -Ev 'windows|nvidia|neuron|e2e-test' | sort -u >> "${IMAGE_LIST}"
fi

# ECP Workload Identity images
if [[ "${INSTALL_ECP:-false}" == "true" ]]; then
  echo "${ECP_GHCR_REGISTRY}/express-compute-auth-proxy:${ECP_CONTROL_PLANE_VERSION}" >> "${IMAGE_LIST}"
  echo "${ECP_GHCR_REGISTRY}/express-compute-workload-identity-webhook:${ECP_CONTROL_PLANE_VERSION}" >> "${IMAGE_LIST}"

  AGENT_CHART=$(ls "${CHARTS_DIR}"/eks-pod-identity-agent-*.tgz 2>/dev/null | head -1 || true)
  if [[ -n "$AGENT_CHART" ]]; then
    helm template eks-pod-identity-agent "$AGENT_CHART" 2>/dev/null | \
      python3 "${EXTRACT_IMAGES_PY}" | sort -u >> "${IMAGE_LIST}"
  fi
fi

# Deduplicate
sort -u -o "${IMAGE_LIST}" "${IMAGE_LIST}"

TOTAL=$(wc -l < "${IMAGE_LIST}")
echo "  Pulling ${TOTAL} add-on images..."

# Install Docker/containerd to pull images for export (use k3s containerd)
# Start k3s temporarily in agent mode for image pulling
# Instead, use ctr with k3s's bundled containerd (which isn't running yet in AMI build)
# Use Docker/skopeo/ctr — simplest is `docker pull` + `docker save`
# AL2023 has Docker available via dnf

sudo dnf install -y docker --quiet 2>/dev/null || true
sudo systemctl start docker 2>/dev/null || true

PULLED_IMAGES=""
while IFS= read -r img; do
  [ -z "$img" ] && continue
  echo "    Pulling: ${img}"
  if sudo docker pull "$img" 2>/dev/null; then
    PULLED_IMAGES="${PULLED_IMAGES} ${img}"
  else
    echo "    Warning: failed to pull ${img}"
  fi
done < "${IMAGE_LIST}"

if [ -n "$PULLED_IMAGES" ]; then
  echo "  Saving add-on images to airgap tarball..."
  sudo docker save ${PULLED_IMAGES} | zstd -T0 -3 | \
    sudo tee "${AIRGAP_DIR}/k3s-xpress-addons.tar.zst" > /dev/null
  echo "✓ Add-on airgap tarball created"
  sudo docker system prune -af 2>/dev/null || true
else
  echo "  Warning: no add-on images were pulled — airgap tarball not created"
fi

sudo systemctl stop docker 2>/dev/null || true
rm -f "${IMAGE_LIST}"

echo "✓ airgap-images complete"
