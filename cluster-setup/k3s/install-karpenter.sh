#!/bin/bash
# install-karpenter.sh — Install Karpenter on k3s-Xpress.
# Called by setup-k3s-xpress.sh after add-ons are installed.
#
# This installs:
#   1. Karpenter controller (same as EKS-D)
#   2. ecp-karpenter-support (EC2NodeClass webhook + ValidationSucceeded controller)
#
# Worker nodes launched by Karpenter:
#   - Use EKS Optimized AMIs (same as EKS-D-Xpress workers)
#   - Authenticate via aws-iam-authenticator (IAM role → system:nodes group)
#   - Join via kubelet bootstrap (NOT k3s agent) — standard kubelet pointing at k3s API server
#   - The k3s API server is a standard Kubernetes API server; kubelet doesn't know/care
#
# Prerequisites:
#   - k3s server running with aws-iam-authenticator webhook enabled
#   - cert-manager installed (for webhook TLS)
#   - Karpenter chart pre-cached in /opt/k3s-xpress/charts/
#   - CLUSTER_NAME, AWS_REGION, TENANT_ID set
set -eo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

source /opt/k3s-xpress/cluster.env
source /opt/k3s-xpress/version.env

# Get region and account from IMDS if not set
if [ -z "${AWS_REGION:-}" ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
fi

if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
fi

CHARTS_DIR="/opt/k3s-xpress/charts"
NODE_IP=$(hostname -I | awk '{print $1}')
CLUSTER_ENDPOINT="https://${NODE_IP}:6443"

# ── 1. Install Karpenter ─────────────────────────────────────────────────────
echo "  Installing Karpenter..."
KARPENTER_CHART=$(ls "${CHARTS_DIR}"/karpenter-*.tgz 2>/dev/null | head -1)

# If chart not pre-cached, pull from public ECR
if [ -z "$KARPENTER_CHART" ]; then
  helm registry logout public.ecr.aws 2>/dev/null || true
  KARPENTER_CHART="oci://public.ecr.aws/karpenter/karpenter"
  KARPENTER_VERSION_FLAG="--version ${KARPENTER_VERSION:-1.13.0}"
else
  KARPENTER_VERSION_FLAG=""
fi

helm upgrade --install karpenter ${KARPENTER_CHART} \
  ${KARPENTER_VERSION_FLAG} \
  --namespace kube-system \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.clusterEndpoint="${CLUSTER_ENDPOINT}" \
  --set settings.interruptionQueue="${CLUSTER_NAME}" \
  --set settings.eksControlPlane=false \
  --set replicas=1 \
  --set controller.resources.requests.cpu=200m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=500m \
  --set controller.resources.limits.memory=512Mi \
  --set topologySpreadConstraints=null \
  --set controller.env[0].name=AWS_REGION \
  --set controller.env[0].value="${AWS_REGION}" \
  --wait --timeout=120s

echo "  ✓ Karpenter installed"

# ── 2. Install ecp-karpenter-support (EC2NodeClass webhook) ───────────────────
echo "  Installing ecp-karpenter-support..."

# Resolve NAT gateway flag
NAT_ENABLED=$(aws ssm get-parameter \
  --name "/express-compute/infra/network/nat-gateway-enabled" \
  --region "${AWS_REGION}" \
  --query Parameter.Value --output text 2>/dev/null || echo "false")

ECP_GHCR_REGISTRY="${ECP_GHCR_REGISTRY:-ghcr.io/codriverlabs}"
EKS_SUPPORT_CHART=$(ls "${CHARTS_DIR}"/express-compute-karpenter-support-*.tgz 2>/dev/null | head -1)
if [ -z "$EKS_SUPPORT_CHART" ]; then
  EKS_SUPPORT_CHART="oci://${ECP_GHCR_REGISTRY}/helm/express-compute-karpenter-support --version ${ECP_CONTROL_PLANE_VERSION}"
fi

# shellcheck disable=SC2086
helm upgrade --install express-compute-karpenter-support ${EKS_SUPPORT_CHART} \
  --namespace kube-system \
  --set clusterIdentity.clusterName="${CLUSTER_NAME}" \
  --set clusterIdentity.tenantId="${TENANT_ID}" \
  --set clusterIdentity.natGatewayEnabled="${NAT_ENABLED}" \
  --set clusterIdentity.publicSubnetId="${PUBLIC_SUBNET_ID:-}" \
  --set clusterIdentity.privateSubnetId="${PRIVATE_SUBNET_ID:-}" \
  --set clusterIdentity.securityGroupId="${SECURITY_GROUP_ID:-}" \
  --wait --timeout=120s

echo "  ✓ ecp-karpenter-support installed"

# ── 3. Publish k3s API server details to SSM (for worker bootstrap) ───────────
echo "  Publishing cluster join credentials to SSM..."

# The k3s token allows node bootstrap — workers use it alongside IAM auth
K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/token)

aws ssm put-parameter \
  --name "/express-compute/cluster/${CLUSTER_NAME}/k3s-url" \
  --value "${CLUSTER_ENDPOINT}" \
  --type "String" \
  --overwrite \
  --region "${AWS_REGION}" || {
  echo "  Warning: could not publish k3s-url to SSM"
}

aws ssm put-parameter \
  --name "/express-compute/cluster/${CLUSTER_NAME}/k3s-token" \
  --value "${K3S_TOKEN}" \
  --type "SecureString" \
  --overwrite \
  --region "${AWS_REGION}" || {
  echo "  Warning: could not publish k3s-token to SSM"
}

echo "  ✓ Cluster join credentials stored in SSM"

# ── 4. Create bootstrap token secret (for kubelet TLS bootstrap) ──────────────
# Worker nodes (EKS Optimized AMIs) use kubelet TLS bootstrapping.
# They present the bootstrap token, the API server validates it, and issues
# a client certificate. This is the same mechanism as kubeadm's bootstrap tokens.
echo "  Creating kubelet bootstrap token..."
BOOTSTRAP_TOKEN_ID=$(openssl rand -hex 3)
BOOTSTRAP_TOKEN_SECRET=$(openssl rand -hex 8)
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN_ID}.${BOOTSTRAP_TOKEN_SECRET}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${BOOTSTRAP_TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: "${BOOTSTRAP_TOKEN_ID}"
  token-secret: "${BOOTSTRAP_TOKEN_SECRET}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:worker"
EOF

# Store bootstrap token in SSM for worker user data scripts
aws ssm put-parameter \
  --name "/express-compute/cluster/${CLUSTER_NAME}/bootstrap-token" \
  --value "${BOOTSTRAP_TOKEN}" \
  --type "SecureString" \
  --overwrite \
  --region "${AWS_REGION}" || {
  echo "  Warning: could not publish bootstrap-token to SSM"
}

# Ensure RBAC allows bootstrap token authentication for node CSR auto-approval
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: express-compute-node-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:bootstrappers:worker
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: express-compute-node-csr-approve
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:bootstrappers:worker
EOF

echo "  ✓ Bootstrap token created and RBAC configured"
echo ""
echo "  ✓ Karpenter + ecp-karpenter-support ready"
echo "    Workers will join via IAM authentication (aws-iam-authenticator)"
echo "    Workers can use EKS Optimized AMIs (standard kubelet bootstrap)"
echo ""
echo "    SSM parameters:"
echo "      /express-compute/cluster/${CLUSTER_NAME}/k3s-url"
echo "      /express-compute/cluster/${CLUSTER_NAME}/k3s-token"
echo "      /express-compute/cluster/${CLUSTER_NAME}/bootstrap-token"
