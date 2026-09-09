#!/bin/bash
# setup-k3s-xpress.sh — Boot-time k3s cluster setup
#
# Assumes AMI-baked prerequisites are already present:
#   k3s binary, airgap images, Helm charts, ECR credential provider.
#
# Runs: k3s server start → wait for readiness → install add-ons → register
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cluster.env is written by TenantEc2Service before instance launch ─────────
if [ ! -f /opt/k3s-xpress/cluster.env ]; then
  echo "Error: /opt/k3s-xpress/cluster.env not found (expected to be pre-seeded by TenantEc2Service)"
  exit 1
fi
source /opt/k3s-xpress/cluster.env
source /opt/k3s-xpress/version.env

# ── Load progress reporting ───────────────────────────────────────────────────
source "${SCRIPT_DIR}/progress.sh"
trap 'fail "Unexpected error at line ${LINENO}: ${BASH_COMMAND}"' ERR

echo "✓ cluster.env loaded (tenant=${TENANT_ID}, cluster=${CLUSTER_NAME})"

echo "=========================================="
echo "k3s-Xpress Cluster Setup"
echo "Developer: ${TENANT_ID}  Cluster: ${CLUSTER_NAME}"
echo "k3s: ${K3S_VERSION}  Kubernetes: ${K3S_KUBERNETES_VERSION}"
echo "=========================================="
update_progress "booting" "Starting k3s cluster setup" 5

# ── Step 1: Resolve instance metadata ─────────────────────────────────────────
echo "Step 1/7: Resolving instance metadata..."
TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
NODE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

if [ -z "${AWS_REGION:-}" ]; then
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region)
fi

echo "    Node IP: ${NODE_IP}"
echo "    Instance: ${INSTANCE_ID}"
echo "    Region: ${AWS_REGION}"
update_progress "provisioning" "Instance metadata resolved" 10

# ── Step 1b: Prepare data volume ──────────────────────────────────────────────
# Dedicated EBS volume for k3s SQLite state — same pattern as EKS-D etcd volume.
# Must mount before k3s starts so state.db lands on the data volume.
echo "Step 1b: Preparing k3s data volume..."
bash "${SCRIPT_DIR}/prepare-data-volume.sh"
update_progress "provisioning" "Data volume ready" 12

# ── Step 2: Write k3s server configuration ────────────────────────────────────
echo "Step 2/7: Writing k3s server configuration..."
sudo mkdir -p /etc/rancher/k3s

# CNI mode: "flannel" (default) or "vpc"
CNI_MODE="${CNI_MODE:-flannel}"
AUTOSCALING_MODE="${AUTOSCALING_MODE:-none}"
echo "    CNI mode: ${CNI_MODE}"
echo "    Autoscaling: ${AUTOSCALING_MODE}"

# ── Step 2b: Configure aws-iam-authenticator (BEFORE k3s start) ───────────────
# This must happen before k3s starts because the API server needs the webhook
# config file to exist at startup. Same requirement as EKS-D (06-install before 07-init).
echo "Step 2b: Configuring aws-iam-authenticator..."
bash "${SCRIPT_DIR}/install-aws-iam-authenticator.sh"

# Build k3s config based on CNI mode
# The kube-apiserver-arg for authentication-token-webhook-config-file enables
# IAM-based authentication for worker nodes (including EKS Optimized AMI nodes
# launched by Karpenter).
if [[ "${CNI_MODE}" == "vpc" ]]; then
  # VPC CNI mode: disable Flannel entirely, let VPC CNI handle networking
  cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml
node-ip: "${NODE_IP}"
node-external-ip: "${NODE_IP}"
tls-san:
  - "${NODE_IP}"
  - "${CLUSTER_NAME}"
disable:
$(echo "${K3S_DISABLE}" | tr ',' '\n' | sed 's/^/  - /')
flannel-backend: "none"
disable-network-policy: true
write-kubeconfig-mode: "0644"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
kube-apiserver-arg:
  - "authentication-token-webhook-config-file=/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml"
kubelet-arg:
  - "image-credential-provider-bin-dir=/usr/bin"
  - "image-credential-provider-config=/var/lib/rancher/k3s/agent/etc/credential-provider-config.yaml"
  - "cloud-provider=external"
node-label:
  - "express-compute.io/cluster-name=${CLUSTER_NAME}"
  - "express-compute.io/tenant-id=${TENANT_ID}"
  - "express-compute.io/cni=vpc"
node-taint: []
EOF
else
  # Flannel mode (default): use k3s built-in VXLAN overlay
  cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml
node-ip: "${NODE_IP}"
node-external-ip: "${NODE_IP}"
tls-san:
  - "${NODE_IP}"
  - "${CLUSTER_NAME}"
disable:
$(echo "${K3S_DISABLE}" | tr ',' '\n' | sed 's/^/  - /')
write-kubeconfig-mode: "0644"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
kube-apiserver-arg:
  - "authentication-token-webhook-config-file=/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml"
kubelet-arg:
  - "image-credential-provider-bin-dir=/usr/bin"
  - "image-credential-provider-config=/var/lib/rancher/k3s/agent/etc/credential-provider-config.yaml"
  - "cloud-provider=external"
node-label:
  - "express-compute.io/cluster-name=${CLUSTER_NAME}"
  - "express-compute.io/tenant-id=${TENANT_ID}"
  - "express-compute.io/cni=flannel"
node-taint: []
EOF
fi

update_progress "provisioning" "k3s configuration written" 15

# ── Step 3: Start k3s server ──────────────────────────────────────────────────
echo "Step 3/7: Starting k3s server..."
update_progress "k3s-starting" "Starting k3s server" 20

# Install k3s service via the install script pattern (just enable systemd unit)
cat <<'EOF' | sudo tee /etc/systemd/system/k3s.service
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/k3s
EnvironmentFile=-/etc/sysconfig/k3s
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service 2>/dev/null'
ExecStart=/usr/local/bin/k3s server
ExecStartPost=/bin/sh -c 'until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 1; done'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable k3s
sudo systemctl start k3s

# Wait for k3s API server readiness
echo "    Waiting for k3s API server..."
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG

for i in $(seq 1 60); do
  if kubectl get --raw /readyz &>/dev/null; then
    echo "✓ k3s API server ready (${i}s)"
    break
  fi
  [ "$i" -eq 60 ] && { echo "ERROR: k3s API server not ready after 60s"; exit 1; }
  sleep 1
done

update_progress "k3s-ready" "k3s server running" 40

# ── Step 4: Wait for system pods ──────────────────────────────────────────────
echo "Step 4/7: Waiting for system pods..."

# VPC CNI mode: install CNI before waiting for node readiness
if [[ "${CNI_MODE}" == "vpc" ]]; then
  echo "    Installing VPC CNI (flannel disabled)..."
  bash "${SCRIPT_DIR}/install-vpc-cni.sh"
fi

kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=60s || {
  echo "Warning: CoreDNS not ready within 60s, continuing..."
}

# Make kubeconfig available to ec2-user
_LOGIN_USER="ec2-user"
_LOGIN_HOME=$(getent passwd "${_LOGIN_USER}" | cut -d: -f6)
if [ -n "${_LOGIN_HOME}" ]; then
  mkdir -p "${_LOGIN_HOME}/.kube"
  cp /etc/rancher/k3s/k3s.yaml "${_LOGIN_HOME}/.kube/config"
  sed -i "s|127.0.0.1|${NODE_IP}|g" "${_LOGIN_HOME}/.kube/config"
  chown -R "${_LOGIN_USER}:${_LOGIN_USER}" "${_LOGIN_HOME}/.kube"
  echo "✓ kubeconfig copied to ${_LOGIN_USER}"
fi

update_progress "provisioning" "System pods ready" 50

# ── Step 5: Install add-ons ───────────────────────────────────────────────────
# Order: cert-manager → ECP Workload Identity → CloudWatch → EBS CSI → metrics-server
# ECP WI must come before CloudWatch/EBS CSI because they use pod-level IAM credentials.
echo "Step 5/7: Installing add-ons..."
update_progress "provisioning" "Installing add-ons" 55
bash "${SCRIPT_DIR}/install-addons.sh"
update_progress "provisioning" "Add-ons installed" 75

# ── Step 5b: Karpenter (if autoscaling enabled) ──────────────────────────────
if [[ "${AUTOSCALING_MODE}" == "karpenter" ]]; then
  echo "Step 5b: Installing Karpenter..."
  update_progress "provisioning" "Installing Karpenter" 78
  bash "${SCRIPT_DIR}/install-karpenter.sh"
  update_progress "provisioning" "Karpenter installed" 85
else
  update_progress "provisioning" "Skipping Karpenter (autoscaling=none)" 85
fi

# ── Step 6: Finalize ──────────────────────────────────────────────────────────
update_progress "provisioning" "Finalizing" 95

# ── Step 7: Mark installation complete ────────────────────────────────────────
echo "Step 7/7: Finalizing..."
sudo touch /opt/k3s-xpress/.installation_complete

echo ""
echo "=========================================="
echo "✓ k3s-Xpress cluster setup complete!"
echo "=========================================="
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""
echo "  Cluster: ${CLUSTER_NAME}"
echo "  k3s:     ${K3S_VERSION}"
echo "  Node:    ${NODE_IP}"

report_ready
