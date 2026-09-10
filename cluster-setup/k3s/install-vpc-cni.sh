#!/bin/bash
# install-vpc-cni.sh — Install AWS VPC CNI on k3s-Xpress.
# Called by setup-k3s-xpress.sh after k3s starts.
#
# Prerequisites:
#   - k3s started with flannel-backend=none
#   - VPC CNI manifest pre-baked at /opt/k3s-xpress/manifests/aws-vpc-cni.yaml
#   - CNI binaries pre-baked at /opt/cni/bin/
#   - VPC CNI images pre-loaded in airgap tarball
set -eo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

source /opt/k3s-xpress/cluster.env

# Get region from IMDS if not set
if [ -z "${AWS_REGION:-}" ]; then
  TOKEN=$(curl -sf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
  AWS_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
fi

# ── Disable ec2-net-utils policy-routes (conflicts with VPC CNI) ──────────────
echo "  Disabling ec2-net-utils policy-routes..."
sudo systemctl disable --now policy-routes@ens5.service policy-routes@ens6.service 2>/dev/null || true
sudo systemctl disable --now refresh-policy-routes@ens5.timer refresh-policy-routes@ens6.timer 2>/dev/null || true

sudo rm -f /run/systemd/network/70-ens*.network.d/ec2net_alias.conf
sudo networkctl reload 2>/dev/null || true

# Remove any stale secondary IPs and ip rules
for iface in $(ip -o link show | awk -F: '/ens/{print $2}' | tr -d ' '); do
  ip -4 addr show dev "$iface" scope global | grep '/32' | awk '{print $2}' | while read addr; do
    sudo ip addr del "$addr" dev "$iface" 2>/dev/null || true
  done
done
ip rule show | grep "proto static" | while read line; do
  prio=$(echo "$line" | cut -d: -f1)
  rule=$(echo "$line" | sed "s/^[0-9]*:\t//")
  sudo ip rule del priority "$prio" $rule 2>/dev/null || true
done
sudo ip route flush cache 2>/dev/null || true
echo "  ✓ ec2-net-utils policy-routes disabled"

# ── Verify CNI binaries are pre-baked ─────────────────────────────────────────
if [ -z "$(ls /opt/cni/bin/ 2>/dev/null)" ]; then
  echo "  WARNING: CNI binaries not pre-baked — VPC CNI init container will extract them (adds ~24s)"
fi

# ── EC2 API connectivity check ────────────────────────────────────────────────
if curl -s --connect-timeout 2 "https://ec2.${AWS_REGION}.amazonaws.com" >/dev/null 2>&1; then
  echo "  ✓ EC2 API reachable (${AWS_REGION})"
else
  echo "  Note: EC2 API not immediately reachable — IPAMD will retry internally"
fi

# ── Apply VPC CNI manifest ────────────────────────────────────────────────────
echo "  Installing AWS VPC CNI..."
MANIFEST="/opt/k3s-xpress/manifests/aws-vpc-cni.yaml"
if [ ! -f "$MANIFEST" ]; then
  echo "  ERROR: VPC CNI manifest not found at ${MANIFEST}" >&2
  echo "  Was the AMI built with VPC CNI support?" >&2
  exit 1
fi

kubectl apply -f "$MANIFEST"

echo "  Waiting for VPC CNI pods to be ready..."
kubectl rollout status daemonset aws-node -n kube-system --timeout=120s || {
  echo "  Warning: aws-node not fully rolled out within 120s"
  kubectl get pods -n kube-system -l k8s-app=aws-node
}

# ── Wait for node to become Ready (CNI configured) ────────────────────────────
echo "  Waiting for node to become Ready..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl wait --for=condition=Ready node/"${NODE_NAME}" --timeout=60s || {
  echo "  Warning: Node not Ready within 60s after VPC CNI install"
}

echo "  ✓ AWS VPC CNI installed"
kubectl get pods -n kube-system -l k8s-app=aws-node
