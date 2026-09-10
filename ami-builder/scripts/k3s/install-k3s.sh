#!/bin/bash
set -e

# k3s-Xpress AMI Installation Script — orchestrator
# Pre-installs k3s, airgap images, Helm charts, and boot scripts
# for sub-2-minute cluster boot with zero runtime downloads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_SETUP_DIR="/tmp/cluster-setup-k3s"

K3S_KUBERNETES_VERSION="${K3S_KUBERNETES_VERSION:-1.35}"
BUILD_TYPE="${BUILD_TYPE:-internal}"

# ── 1. Source version pins ────────────────────────────────────────────────────
echo "==> Loading k3s component versions for Kubernetes ${K3S_KUBERNETES_VERSION}..."
source "${SCRIPT_DIR}/component-versions.env"

# Resolve k3s version based on Kubernetes track
if [[ "${K3S_KUBERNETES_VERSION}" == "1.36" ]]; then
  K3S_VERSION="${K3S_VERSION_136}"
else
  K3S_VERSION="${K3S_VERSION_135}"
fi

echo "    k3s version: ${K3S_VERSION}"
echo "    cert-manager: ${CERT_MANAGER_VERSION}"
echo "    CloudWatch agent: ${CLOUDWATCH_AGENT_VERSION}"
echo "    ECP version: ${ECP_CONTROL_PLANE_VERSION}"

sudo mkdir -p /opt/k3s-xpress
cat <<EOF | sudo tee /opt/k3s-xpress/version.env
K3S_KUBERNETES_VERSION=${K3S_KUBERNETES_VERSION}
K3S_VERSION=${K3S_VERSION}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}
CLOUDWATCH_AGENT_VERSION=${CLOUDWATCH_AGENT_VERSION}
ECP_CONTROL_PLANE_VERSION=${ECP_CONTROL_PLANE_VERSION}
INSTALL_ECP=${INSTALL_ECP}
K3S_DISABLE=${K3S_DISABLE}
EOF

# ── 2. Detect architecture ────────────────────────────────────────────────────
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
[ "$ARCH" = "x86_64" ] && ARCH="amd64"
echo "    Architecture: ${ARCH}"

# ── 3. Install k3s binary ─────────────────────────────────────────────────────
echo "==> Installing k3s binary (${K3S_VERSION})..."
K3S_TAG=$(echo "${K3S_VERSION}" | sed 's/+/%2B/g')
K3S_BIN_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_TAG}/k3s"
[ "$ARCH" = "arm64" ] && K3S_BIN_URL="${K3S_BIN_URL}-arm64"

curl -fsSL "${K3S_BIN_URL}" -o /tmp/k3s
sudo install -o root -g root -m 0755 /tmp/k3s /usr/local/bin/k3s
rm -f /tmp/k3s

# Create kubectl symlink
sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
sudo ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
sudo ln -sf /usr/local/bin/k3s /usr/local/bin/ctr

echo "✓ k3s binary installed: $(k3s --version)"

# ── 4. Install ecr-credential-provider ────────────────────────────────────────
echo "==> Installing ecr-credential-provider..."
sudo install -o root -g root -m 0755 /tmp/ecr-credential-provider /usr/bin/ecr-credential-provider
rm -f /tmp/ecr-credential-provider

# ── 5. Install syft ───────────────────────────────────────────────────────────
echo "==> Installing syft (${SYFT_VERSION})..."
curl -sL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${ARCH}.tar.gz" \
  -o /tmp/syft.tar.gz
tar -xzf /tmp/syft.tar.gz -C /tmp syft
sudo install -o root -g root -m 0755 /tmp/syft /usr/local/bin/syft
rm -f /tmp/syft.tar.gz /tmp/syft

# ── 6. Install ecp CLI ────────────────────────────────────────────────────────
echo "==> Installing ecp CLI..."
if [[ "${INSTALL_ECP:-false}" == "true" ]]; then
  ECP_CLI_URL="https://github.com/codriverlabs/express-compute-control-plane/releases/download/v${ECP_CONTROL_PLANE_VERSION}/ecp-cli-${ECP_CONTROL_PLANE_VERSION}-linux-${ARCH}"
  curl -fsSL "$ECP_CLI_URL" -o /tmp/ecp
  sudo install -o root -g root -m 0755 /tmp/ecp /usr/local/bin/ecp
  rm -f /tmp/ecp
  echo "✓ ecp CLI installed"
else
  echo "  Skipping ecp CLI (INSTALL_ECP=false)"
fi

# ── 7. Install Helm ───────────────────────────────────────────────────────────
echo "==> Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── 8. System configuration ──────────────────────────────────────────────────
echo "==> Configuring kernel networking settings..."
cat <<'EOF' | sudo tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
nf_conntrack
EOF
sudo modprobe overlay br_netfilter nf_conntrack
cat <<'EOF' | sudo tee /etc/sysctl.d/99-k3s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

echo "==> Disabling swap..."
sudo swapoff -a
sudo touch /etc/systemd/zram-generator.conf
sudo sed -i '/ swap /d' /etc/fstab 2>/dev/null || true

echo "==> Configuring ECR credential provider for k3s..."
sudo mkdir -p /etc/rancher/k3s
cat <<'EOF' | sudo tee /etc/rancher/k3s/registries.yaml
mirrors: {}
EOF

sudo mkdir -p /var/lib/rancher/k3s/agent/etc
cat <<'EOF' | sudo tee /var/lib/rancher/k3s/agent/etc/credential-provider-config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "public.ecr.aws"
    defaultCacheDuration: 12h
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

# ── 9. Download airgap images ─────────────────────────────────────────────────
echo "==> Downloading k3s airgap images..."
AIRGAP_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_TAG}/k3s-airgap-images-${ARCH}.tar.zst"
sudo mkdir -p /var/lib/rancher/k3s/agent/images
curl -fsSL "${AIRGAP_URL}" -o /tmp/k3s-airgap-images.tar.zst
sudo mv /tmp/k3s-airgap-images.tar.zst /var/lib/rancher/k3s/agent/images/
echo "✓ k3s airgap images staged"

# ── 10. Pull add-on images and charts ─────────────────────────────────────────
echo "==> Pulling add-on Helm charts and building airgap tarball..."
sudo mkdir -p /opt/k3s-xpress/charts

# ECR authentication for pull-through cache (internal builds)
ACCOUNT_ID=""
set +e
for i in $(seq 1 12); do
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
  echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$' && break
  sleep 5
done
set -e
echo "${ACCOUNT_ID}" | grep -qE '^[0-9]{12}$' || \
  { echo "ERROR: Could not obtain IAM credentials after 60s" >&2; exit 1; }

REGION=$(aws sts get-caller-identity --query 'Arn' --output text | cut -d: -f4)
if [ -z "${REGION}" ] || [ "${REGION}" = "None" ]; then
  TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region)
fi

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_PASSWORD=$(aws ecr get-login-password --region "${REGION}")
echo "${ECR_PASSWORD}" | helm registry login --username AWS --password-stdin "${ECR_REGISTRY}"

if [[ "${BUILD_TYPE}" == "release" ]]; then
  QUAY_CACHE="quay.io"
  PUBLIC_ECR_CACHE="public.ecr.aws"
  echo "    Build type: release (direct upstream registries)"
else
  QUAY_CACHE="${ECR_REGISTRY}/quay-io"
  PUBLIC_ECR_CACHE="${ECR_REGISTRY}/public-ecr"
  echo "    Build type: internal (pull-through cache: ${ECR_REGISTRY})"
fi

# cert-manager chart
echo "  Pulling cert-manager chart (${CERT_MANAGER_VERSION})..."
helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
helm pull jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" --destination /tmp
sudo mv /tmp/cert-manager-*.tgz /opt/k3s-xpress/charts/

# CloudWatch chart
echo "  Pulling CloudWatch Observability chart..."
helm repo add aws-observability \
  https://aws-observability.github.io/helm-charts 2>/dev/null || true
helm repo update aws-observability
helm pull aws-observability/amazon-cloudwatch-observability --destination /tmp
sudo mv /tmp/amazon-cloudwatch-observability-*.tgz /opt/k3s-xpress/charts/

# EBS CSI chart
echo "  Pulling EBS CSI Driver chart..."
helm repo add aws-ebs-csi-driver \
  https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update aws-ebs-csi-driver
helm pull aws-ebs-csi-driver/aws-ebs-csi-driver --destination /tmp
sudo mv /tmp/aws-ebs-csi-driver-*.tgz /opt/k3s-xpress/charts/

# ECP Workload Identity charts
if [[ "${INSTALL_ECP:-false}" == "true" ]]; then
  echo "  Pulling Express Compute Helm charts (v${ECP_CONTROL_PLANE_VERSION})..."
  for chart in express-compute-workload-identity-webhook express-compute-auth-proxy express-compute-karpenter-support; do
    helm pull "oci://${ECP_GHCR_REGISTRY}/helm/${chart}" \
      --version "${ECP_CONTROL_PLANE_VERSION}" --destination /tmp || true
  done
  sudo mv /tmp/express-compute-*.tgz /opt/k3s-xpress/charts/ 2>/dev/null || true

  echo "  Pulling eks-pod-identity-agent chart..."
  mkdir -p /tmp/eks-pod-identity-agent
  curl -sL https://github.com/aws/eks-pod-identity-agent/archive/refs/heads/main.tar.gz | \
    tar xz --strip-components=3 -C /tmp/eks-pod-identity-agent \
      eks-pod-identity-agent-main/charts/eks-pod-identity-agent || true
  if [ -f /tmp/eks-pod-identity-agent/Chart.yaml ]; then
    helm package /tmp/eks-pod-identity-agent --destination /tmp || true
    sudo mv /tmp/eks-pod-identity-agent-*.tgz /opt/k3s-xpress/charts/ 2>/dev/null || true
  fi
  rm -rf /tmp/eks-pod-identity-agent
fi

# ── 11. Build add-on airgap tarball ───────────────────────────────────────────
echo "==> Building add-on airgap image tarball..."
bash "${SCRIPT_DIR}/airgap-images.sh"

# ── 12. Stage boot scripts ────────────────────────────────────────────────────
echo "==> Staging k3s cluster-setup scripts..."
sudo mkdir -p /opt/k3s-xpress/cluster-setup
sudo cp -r "${K3S_SETUP_DIR}"/* /opt/k3s-xpress/cluster-setup/
sudo chmod +x /opt/k3s-xpress/cluster-setup/*.sh

# ── 13. Install ecp-boot.service (k3s variant) ───────────────────────────────
echo "==> Installing k3s-xpress-boot.service..."
cat <<'EOF' | sudo tee /etc/systemd/system/k3s-xpress-boot.service
[Unit]
Description=k3s-Xpress Cluster Bootstrap
After=network-online.target cloud-final.service
Wants=network-online.target
ConditionPathExists=!/opt/k3s-xpress/.installation_complete

[Service]
Type=oneshot
RemainAfterExit=true
Environment=HOME=/root
WorkingDirectory=/opt/k3s-xpress/cluster-setup
ExecStart=/bin/bash /opt/k3s-xpress/cluster-setup/setup-k3s-xpress.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable k3s-xpress-boot.service

# ── 14. Clean up ──────────────────────────────────────────────────────────────
echo "==> Cleaning up ECR credentials..."
helm registry logout "${ECR_REGISTRY}" 2>/dev/null || true

echo ""
echo "==> k3s-Xpress AMI build complete!"
echo "    k3s binary:    /usr/local/bin/k3s (${K3S_VERSION})"
echo "    Airgap images: /var/lib/rancher/k3s/agent/images/"
echo "    Charts:        /opt/k3s-xpress/charts/"
echo "    Boot scripts:  /opt/k3s-xpress/cluster-setup/"
echo "    Versions:      /opt/k3s-xpress/version.env"
