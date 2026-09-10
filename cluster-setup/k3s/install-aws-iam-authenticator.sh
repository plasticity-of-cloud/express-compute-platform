#!/bin/bash
# install-aws-iam-authenticator.sh — Configure IAM-based authentication on k3s.
#
# Must run BEFORE k3s server starts, because k3s needs the webhook config
# to be present at API server startup time.
#
# This enables:
#   1. Worker nodes (including EKS Optimized AMI nodes launched by Karpenter)
#      to authenticate via their IAM instance role
#   2. Users to authenticate via `aws eks get-token` / aws-iam-authenticator
#   3. Same authentication model as EKS-D-Xpress
#
# k3s API server flags are passed via config.yaml:
#   kube-apiserver-arg:
#     - "authentication-token-webhook-config-file=/etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml"
#
# Files created:
#   /etc/kubernetes/aws-iam-authenticator/config.yaml    — authenticator server config
#   /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml — webhook kubeconfig for API server
#   /var/lib/rancher/k3s/server/manifests/aws-iam-authenticator.yaml — auto-deploy manifest
#
set -eo pipefail

source /opt/k3s-xpress/cluster.env
source /opt/k3s-xpress/version.env

if [ -z "${TENANT_ID}" ] || [ -z "${CLUSTER_NAME}" ]; then
  echo "Error: TENANT_ID and CLUSTER_NAME must be set in cluster.env"
  exit 1
fi

if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  # Resolve from IMDS
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token)
  AWS_ACCOUNT_ID=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/identity-credentials/ec2/info | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['AccountId'])" 2>/dev/null || \
    aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
fi

if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "Error: Could not determine AWS_ACCOUNT_ID"
  exit 1
fi

NODE_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/express-compute-tenant-${TENANT_ID}-instance-role"

# The aws-iam-authenticator image — use the same image from EKS-D release
# manifests or fall back to public ECR
AWS_IAM_AUTHENTICATOR_IMAGE="${AWS_IAM_AUTHENTICATOR_IMAGE:-public.ecr.aws/eks-distro/kubernetes-sigs/aws-iam-authenticator:v0.7.13-eks-1-35-9}"

echo "Configuring aws-iam-authenticator for k3s..."
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Region:    ${AWS_REGION}"
echo "  Node role: ${NODE_ROLE_ARN}"
echo "  Image:     ${AWS_IAM_AUTHENTICATOR_IMAGE}"

# ── Create directories ────────────────────────────────────────────────────────
sudo mkdir -p /etc/kubernetes/aws-iam-authenticator
sudo mkdir -p /var/aws-iam-authenticator
sudo chmod 777 /var/aws-iam-authenticator

# k3s auto-deploy manifests directory (k3s applies anything here at startup)
sudo mkdir -p /var/lib/rancher/k3s/server/manifests

# ── 1. Authenticator server config ───────────────────────────────────────────
cat <<EOF | sudo tee /etc/kubernetes/aws-iam-authenticator/config.yaml
clusterID: ${CLUSTER_NAME}
server:
  mapRoles:
    - roleARN: ${NODE_ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

# ── 2. Webhook kubeconfig (consumed by kube-apiserver) ────────────────────────
cat <<EOF | sudo tee /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: aws-iam-authenticator
    cluster:
      server: https://localhost:21362/authenticate
      insecure-skip-tls-verify: true
users:
  - name: kube-apiserver
contexts:
  - name: aws-iam-authenticator
    context:
      cluster: aws-iam-authenticator
      user: kube-apiserver
current-context: aws-iam-authenticator
EOF

# ── 3. k3s auto-deploy manifest (Pod) ────────────────────────────────────────
# k3s applies files in /var/lib/rancher/k3s/server/manifests/ at startup.
# Using a Pod spec here (hostNetwork, same as EKS-D static pod approach).
cat <<EOF | sudo tee /var/lib/rancher/k3s/server/manifests/aws-iam-authenticator.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aws-iam-authenticator
  namespace: kube-system
  labels:
    app: aws-iam-authenticator
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  tolerations:
    - operator: Exists
  containers:
    - name: aws-iam-authenticator
      image: ${AWS_IAM_AUTHENTICATOR_IMAGE}
      args:
        - server
        - --config=/etc/aws-iam-authenticator/config.yaml
        - --state-dir=/var/aws-iam-authenticator
        - --generate-kubeconfig=/etc/aws-iam-authenticator/kubeconfig.yaml
        - --kubeconfig-pregenerated=true
      env:
        - name: AWS_REGION
          value: ${AWS_REGION}
        - name: AWS_DEFAULT_REGION
          value: ${AWS_REGION}
      volumeMounts:
        - name: config
          mountPath: /etc/aws-iam-authenticator
        - name: state
          mountPath: /var/aws-iam-authenticator
  volumes:
    - name: config
      hostPath:
        path: /etc/kubernetes/aws-iam-authenticator
    - name: state
      hostPath:
        path: /var/aws-iam-authenticator
        type: DirectoryOrCreate
EOF

echo "✓ aws-iam-authenticator configured for k3s"
echo "  Config:     /etc/kubernetes/aws-iam-authenticator/config.yaml"
echo "  Webhook:    /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml"
echo "  Manifest:   /var/lib/rancher/k3s/server/manifests/aws-iam-authenticator.yaml"
