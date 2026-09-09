AWS_REGION         ?= us-east-1
KUBERNETES_VERSION ?= 1.35
AMI_VERSION        ?= $(shell date +%Y%m%d-%H%M)
ARCH               ?= arm64
BUILD_TYPE         ?= internal

DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(DIR)/..)

.PHONY: all ami build stage packer-init ensure-packer clean-sgs sign
.PHONY: k3s k3s-ami k3s-build k3s-stage k3s-packer-init k3s-sign

all: ami

# ═══════════════════════════════════════════════════════════════════════════════
# EKS-D Golden AMI targets
# ═══════════════════════════════════════════════════════════════════════════════

ami: stage build clean-sgs sign

_ONLY = $(if $(filter arm64,$(ARCH)),-only=amazon-ebs.arm64,$(if $(filter x86_64,$(ARCH)),-only=amazon-ebs.x86_64,))

build: packer-init
	@mkdir -p "$(DIR)output"
	PACKER_LOG=1 PACKER_LOG_PATH="$(ROOT)/packer-build-$(AMI_VERSION).log" \
	packer build \
	  $(_ONLY) \
	  -var "aws_region=$(AWS_REGION)" \
	  -var "kubernetes_version=$(KUBERNETES_VERSION)" \
	  -var "ami_version=$(AMI_VERSION)" \
	  -var "build_type=$(BUILD_TYPE)" \
	  "$(DIR)ecp-golden-ami.pkr.hcl"

stage:
	@mkdir -p "$(DIR)files"
	@GOARCHES=$$(case '$(ARCH)' in arm64) echo arm64;; x86_64) echo amd64;; both) echo 'amd64 arm64';; esac); \
	for GOARCH in $$GOARCHES; do \
	  ARCH_DIR=$$([ "$$GOARCH" = "amd64" ] && echo x86_64 || echo arm64); \
	  SRC="$(ROOT)/cluster-setup/$$ARCH_DIR/ecr-credential-provider-$(KUBERNETES_VERSION)"; \
	  [ -f "$$SRC" ] || SRC="$(ROOT)/cluster-setup/$$ARCH_DIR/ecr-credential-provider"; \
	  [ -f "$$SRC" ] || { echo "ERROR: ecr-credential-provider not found for $$GOARCH (k8s $(KUBERNETES_VERSION))"; exit 1; }; \
	  cp "$$SRC" "$(DIR)files/ecr-credential-provider-$$GOARCH"; \
	  chmod +x "$(DIR)files/ecr-credential-provider-$$GOARCH"; \
	  echo "✓ staged ecr-credential-provider-$$GOARCH"; \
	done

packer-init: ensure-packer
	packer init "$(DIR)ecp-golden-ami.pkr.hcl"

# ═══════════════════════════════════════════════════════════════════════════════
# k3s-Xpress Golden AMI targets
# ═══════════════════════════════════════════════════════════════════════════════

k3s: k3s-ami
k3s-ami: k3s-stage k3s-build clean-sgs k3s-sign

k3s-build: k3s-packer-init
	@mkdir -p "$(DIR)output"
	PACKER_LOG=1 PACKER_LOG_PATH="$(ROOT)/packer-k3s-build-$(AMI_VERSION).log" \
	packer build \
	  $(_ONLY) \
	  -var "aws_region=$(AWS_REGION)" \
	  -var "k3s_kubernetes_version=$(KUBERNETES_VERSION)" \
	  -var "ami_version=$(AMI_VERSION)" \
	  -var "build_type=$(BUILD_TYPE)" \
	  "$(DIR)k3s-xpress.pkr.hcl"

k3s-stage:
	@mkdir -p "$(DIR)files"
	@GOARCHES=$$(case '$(ARCH)' in arm64) echo arm64;; x86_64) echo amd64;; both) echo 'amd64 arm64';; esac); \
	for GOARCH in $$GOARCHES; do \
	  ARCH_DIR=$$([ "$$GOARCH" = "amd64" ] && echo x86_64 || echo arm64); \
	  SRC="$(ROOT)/cluster-setup/$$ARCH_DIR/ecr-credential-provider-$(KUBERNETES_VERSION)"; \
	  [ -f "$$SRC" ] || SRC="$(ROOT)/cluster-setup/$$ARCH_DIR/ecr-credential-provider"; \
	  [ -f "$$SRC" ] || { echo "ERROR: ecr-credential-provider not found for $$GOARCH (k8s $(KUBERNETES_VERSION))"; exit 1; }; \
	  cp "$$SRC" "$(DIR)files/ecr-credential-provider-$$GOARCH"; \
	  chmod +x "$(DIR)files/ecr-credential-provider-$$GOARCH"; \
	  echo "✓ staged ecr-credential-provider-$$GOARCH (k3s)"; \
	done

k3s-packer-init: ensure-packer
	packer init "$(DIR)k3s-xpress.pkr.hcl"

k3s-sign:
	MANIFEST_FILE="$(DIR)output/packer-manifest-k3s.json" \
	AMI_VERSION=$(AMI_VERSION) AWS_REGION=$(AWS_REGION) bash "$(DIR)scripts/sign-ami.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Shared targets
# ═══════════════════════════════════════════════════════════════════════════════

ensure-packer:
	@command -v packer >/dev/null 2>&1 || { \
	  VERSION=$$(grep '^packer ' "$(ROOT)/.tool-versions" | awk '{print $$2}'); \
	  MACH=$$(uname -m); [ "$$MACH" = "aarch64" ] && MACH=arm64 || MACH=amd64; \
	  OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
	  curl -fsSL "https://releases.hashicorp.com/packer/$$VERSION/packer_$${VERSION}_$${OS}_$${MACH}.zip" -o /tmp/packer.zip; \
	  unzip -o /tmp/packer.zip -d /tmp && sudo mv /tmp/packer /usr/local/bin/packer && rm /tmp/packer.zip; \
	  echo "✓ packer $$VERSION installed"; \
	}

clean-sgs:
	@aws ec2 describe-security-groups --region "$(AWS_REGION)" \
	  --filters "Name=group-name,Values=packer_*" \
	  --query 'SecurityGroups[].GroupId' --output text \
	| tr '\t' '\n' | while read -r sg; do \
	  [ -z "$$sg" ] && continue; \
	  echo "Deleting stale SG: $$sg"; \
	  aws ec2 delete-security-group --group-id "$$sg" --region "$(AWS_REGION)" 2>/dev/null || true; \
	done

sign:
	AMI_VERSION=$(AMI_VERSION) AWS_REGION=$(AWS_REGION) bash "$(DIR)scripts/sign-ami.sh"
