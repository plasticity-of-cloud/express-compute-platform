#!/usr/bin/env bash
# sign-ami.sh — KMS-sign AMI attestations after a packer build.
#
# Reads ami-manifest-entries.json produced by packer, creates a JSON
# attestation per AMI, signs it with the KMS key stored in SSM, and
# stores the base64 signature back in SSM + tags the AMI.
#
# Usage:
#   AMI_VERSION=20260603-1445 AWS_REGION=us-east-1 ./ami-builder/scripts/sign-ami.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST_FILE:-${SCRIPT_DIR}/../output/ami-manifest-entries.json}"
AMI_VERSION="${AMI_VERSION:?set AMI_VERSION}"
AWS_REGION="${AWS_REGION:?set AWS_REGION}"

[ -f "${MANIFEST}" ] || { echo "ERROR: ${MANIFEST} not found — run packer build first" >&2; exit 1; }

KEY_ARN=$(aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/express-compute/infra/kms/ami-signing-key-arn" \
  --query 'Parameter.Value' --output text)
echo "==> Signing with KMS key: ${KEY_ARN}"

python3 - "${MANIFEST}" "${KEY_ARN}" "${AMI_VERSION}" <<'PYEOF'
import json, sys, subprocess, datetime, tempfile, os, base64

manifest_path, key_arn, ami_version = sys.argv[1], sys.argv[2], sys.argv[3]
entries = json.load(open(manifest_path))
sig_entries = []

for e in entries:
    attestation_obj = {
        "ami_id":             e["ami_id"],
        "arch":               e["arch"],
        "kubernetes_version": e["kubernetes_version"],
        "ami_version":        ami_version,
        "timestamp":          datetime.datetime.utcnow().isoformat() + "Z",
    }
    attestation = json.dumps(attestation_obj, sort_keys=True)

    with tempfile.NamedTemporaryFile(delete=False, suffix=".json", mode="w") as f:
        f.write(attestation)
        tmp = f.name

    try:
        sig = subprocess.check_output([
            "aws", "kms", "sign",
            "--region", e["region"],
            "--key-id", key_arn,
            "--message-type", "RAW",
            "--signing-algorithm", "RSASSA_PKCS1_V1_5_SHA_256",
            "--message", f"fileb://{tmp}",
            "--query", "Signature",
            "--output", "text",
        ]).decode().strip()
    finally:
        os.unlink(tmp)

    # Store signature in SSM (internal use)
    subprocess.run([
        "aws", "ssm", "put-parameter",
        "--region", e["region"],
        "--name", f"/express-compute/infra/ami/{e['arch']}/{e['kubernetes_version']}/signature",
        "--value", sig,
        "--type", "String", "--overwrite",
    ], check=True)

    # Write to local sig entries file for bundling in the release artifact
    sig_entries.append({
        "ami_id":             e["ami_id"],
        "arch":               e["arch"],
        "kubernetes_version": e["kubernetes_version"],
        "ami_version":        ami_version,
        "timestamp":          attestation_obj["timestamp"],
        "signature":          sig,
    })

    # Tag the AMI so consumers can verify provenance
    subprocess.run([
        "aws", "ec2", "create-tags",
        "--region", e["region"],
        "--resources", e["ami_id"],
        "--tags",
        f"Key=SigningKeyArn,Value={key_arn}",
        "Key=Signed,Value=true",
        f"Key=SigningTimestamp,Value={attestation_obj['timestamp']}",
    ], check=True)

    print(f"✓ Signed {e['ami_id']} ({e['arch']}) → SSM + ami-signatures-entries.json")

json.dump(sig_entries, open(os.path.join(os.path.dirname(manifest_path), "ami-signatures-entries.json"), "w"), indent=2)
PYEOF
