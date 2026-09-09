#!/bin/bash
# prepare-data-volume.sh — Mount the dedicated k3s data EBS volume.
#
# Mirrors EKS-D's 05-prepare-etcd.sh. The data volume is attached by the
# launch template at /dev/sdf (or /dev/nvme1n1 on Nitro instances).
# SQLite state.db lives here, surviving root volume replacement.
#
# Must run BEFORE k3s server starts.
set -eo pipefail

DATA_DIR="/var/lib/rancher/k3s/server/db"
DATA_LABEL="k3s-data"

# Resolve device — NVMe alias on Nitro instances
DATA_DEVICE=""
for dev in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
  if [ -b "$dev" ]; then
    DATA_DEVICE="$dev"
    break
  fi
done

if [ -z "$DATA_DEVICE" ]; then
  echo "  Warning: no data volume found at /dev/nvme1n1, /dev/sdf, or /dev/xvdf"
  echo "  k3s will use root volume for state (no data durability separation)"
  exit 0
fi

echo "  Data device: ${DATA_DEVICE}"

sudo mkdir -p "${DATA_DIR}"

# Format only if not already formatted (first boot or fresh volume)
if ! sudo blkid "${DATA_DEVICE}" &>/dev/null; then
  echo "  Formatting ${DATA_DEVICE} as ext4..."
  sudo mkfs.ext4 -L "${DATA_LABEL}" "${DATA_DEVICE}"
fi

# Mount
if ! mountpoint -q "${DATA_DIR}"; then
  sudo mount "${DATA_DEVICE}" "${DATA_DIR}"
fi

# Persist across reboots
if ! grep -q "${DATA_LABEL}" /etc/fstab; then
  echo "LABEL=${DATA_LABEL} ${DATA_DIR} ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
fi

# Ensure k3s can write to it
sudo chmod 750 "${DATA_DIR}"

echo "  ✓ k3s data volume mounted at ${DATA_DIR} (${DATA_DEVICE})"
