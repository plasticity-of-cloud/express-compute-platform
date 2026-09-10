packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region" { type = string }
variable "k3s_kubernetes_version" {
  type    = string
  default = "1.35"
}
variable "ami_version" { type = string }
variable "project_name" {
  type    = string
  default = "express-compute-managed-k8s-infra"
}
variable "build_type" {
  type    = string
  default = "internal"
  # "release"  — direct upstream registries (no pull-through cache); used for GitHub releases
  # "internal" — pull-through cache in private ECR; used for internal/customer builds
}

source "amazon-ebs" "x86_64" {
  region        = var.aws_region
  instance_type = "c6a.large"

  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = "k3s-xpress-x86_64-${var.ami_version}"
  ami_description = "k3s-Xpress ${var.k3s_kubernetes_version} x86_64 - ${var.ami_version}"
  ssh_username    = "ec2-user"

  iam_instance_profile = "express-compute-packer-builder"

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = 15
    delete_on_termination = true
  }

  run_tags = {
    Name      = "k3s-xpress-builder-x86_64"
    Platform  = "k3s-xpress"
    ManagedBy = "Packer"
  }

  tags = {
    Name              = "k3s-xpress-x86_64-${var.ami_version}"
    Platform          = "k3s-xpress"
    Project           = var.project_name
    Distribution      = "k3s"
    KubernetesVersion = var.k3s_kubernetes_version
    ManagedBy         = "Packer"
  }
}

source "amazon-ebs" "arm64" {
  region        = var.aws_region
  instance_type = "c6g.large"

  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023*-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ami_name        = "k3s-xpress-arm64-${var.ami_version}"
  ami_description = "k3s-Xpress ${var.k3s_kubernetes_version} arm64 - ${var.ami_version}"
  ssh_username    = "ec2-user"

  iam_instance_profile = "express-compute-packer-builder"

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = 15
    delete_on_termination = true
  }

  run_tags = {
    Name      = "k3s-xpress-builder-arm64"
    Platform  = "k3s-xpress"
    ManagedBy = "Packer"
  }

  tags = {
    Name              = "k3s-xpress-arm64-${var.ami_version}"
    Platform          = "k3s-xpress"
    Project           = var.project_name
    Distribution      = "k3s"
    KubernetesVersion = var.k3s_kubernetes_version
    ManagedBy         = "Packer"
  }
}

build {
  sources = ["source.amazon-ebs.x86_64", "source.amazon-ebs.arm64"]

  provisioner "file" {
    source      = "${path.root}/../cluster-setup/k3s"
    destination = "/tmp/cluster-setup-k3s"
  }

  provisioner "file" {
    source      = "${path.root}/../cluster-setup/progress.sh"
    destination = "/tmp/cluster-setup-k3s/progress.sh"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/k3s"
    destination = "/tmp/scripts-k3s"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/extract-images.py"
    destination = "/tmp/extract-images.py"
  }

  provisioner "file" {
    source      = "${path.root}/files/ecr-credential-provider-${source.name == "x86_64" ? "amd64" : "arm64"}"
    destination = "/tmp/ecr-credential-provider"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/scripts-k3s/*.sh",
      "export K3S_KUBERNETES_VERSION=${var.k3s_kubernetes_version}",
      "export BUILD_TYPE=${var.build_type}",
      "sudo -E bash /tmp/scripts-k3s/install-k3s.sh"
    ]
  }

  # Generate SBOM of the installed filesystem before the AMI is snapshotted
  provisioner "shell" {
    inline = [
      "sudo syft dir:/ --exclude './**/proc/**' --exclude './**/sys/**' --exclude './**/dev/**' --exclude './**/tmp/**' -o spdx-json > /tmp/sbom.spdx.json",
      "echo '✓ SBOM generated'"
    ]
  }

  provisioner "file" {
    source      = "/tmp/sbom.spdx.json"
    destination = "${path.root}/output/sbom-k3s-${source.name}-${var.ami_version}.spdx.json"
    direction   = "download"
  }

  post-processor "manifest" {
    output     = "output/packer-manifest-k3s.json"
    strip_path = true
  }

  post-processor "shell-local" {
    inline = [
      "python3 -c \"\nimport json, sys, os\nos.makedirs('output', exist_ok=True)\ndata = json.load(open('output/packer-manifest-k3s.json'))\nlast_uuid = data['last_run_uuid']\nbuilds = [b for b in data['builds'] if b.get('packer_run_uuid') == last_uuid]\nentries = []\nfor b in builds:\n    region, ami_id = b['artifact_id'].split(':')\n    arch = b['name']\n    entries.append({'kubernetes_version': '${var.k3s_kubernetes_version}', 'arch': arch, 'region': region, 'ami_id': ami_id, 'distribution': 'k3s'})\n    import subprocess\n    subprocess.run(['aws','ssm','put-parameter','--name',f'/express-compute/infra/ami/k3s/{arch}/${var.k3s_kubernetes_version}','--value',ami_id,'--type','String','--overwrite','--region',region], check=True)\n    print(f'Stored /express-compute/infra/ami/k3s/{arch}/${var.k3s_kubernetes_version} -> {ami_id}')\njson.dump(entries, open('output/ami-manifest-k3s-entries.json','w'), indent=2)\n\""
    ]
  }
}
