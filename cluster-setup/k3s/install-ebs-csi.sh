#!/bin/bash
# install-ebs-csi.sh — Install AWS EBS CSI Driver on k3s-Xpress.
# Called by install-addons.sh at boot time.
#
# Provides persistent EBS-backed volumes (gp3 default StorageClass).
# The chart and images are pre-cached in the golden AMI.
set -eo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

source /opt/k3s-xpress/cluster.env
source /opt/k3s-xpress/version.env

CHARTS_DIR="/opt/k3s-xpress/charts"

# Get region from IMDS if not set
if [ -z "${AWS_REGION:-}" ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
fi

echo "  Installing EBS CSI Driver..."

CHART=$(ls "${CHARTS_DIR}"/aws-ebs-csi-driver-*.tgz 2>/dev/null | head -1)
if [ -z "$CHART" ]; then
  echo "  Warning: EBS CSI chart not found in ${CHARTS_DIR}, pulling from upstream..."
  helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
  helm repo update aws-ebs-csi-driver
  CHART="aws-ebs-csi-driver/aws-ebs-csi-driver"
fi

helm upgrade --install aws-ebs-csi-driver "$CHART" \
  --namespace kube-system \
  --set controller.serviceAccount.create=true \
  --set controller.k8sTagClusterId="${CLUSTER_NAME}" \
  --set controller.replicaCount=1 \
  --set controller.region="${AWS_REGION}" \
  --set node.enableWindows=false \
  --timeout=60s

# Create default gp3 StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

echo "  Waiting for EBS CSI node pods..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=aws-ebs-csi-driver,app.kubernetes.io/component=csi-driver \
  -n kube-system --timeout=30s 2>/dev/null || {
  echo "  Note: EBS CSI pods not ready within 30s — will reconcile"
}

echo "  ✓ EBS CSI Driver installed (gp3 default StorageClass)"
