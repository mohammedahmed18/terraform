#!/usr/bin/env bash
# Generates a large, realistic Terraform config using terraform_data resources.
# terraform_data is a built-in provider — no plugins, no network, no mocks.
#
# Usage: ./generate_config.sh <output_dir> [num_resources]
#   default num_resources=500

set -euo pipefail

OUTDIR="${1:?Usage: generate_config.sh <output_dir> [num_resources]}"
NUM="${2:-500}"

NUM_MODULES=10
NUM_PER_MODULE=$((NUM / NUM_MODULES))
NUM_TOP_LEVEL=50
NUM_LOCALS=100

mkdir -p "$OUTDIR"

# --- main.tf ---
cat > "$OUTDIR/main.tf" <<'HEADER'
terraform {
  required_version = ">= 1.0"
}

HEADER

# Locals block — heavily referenced, stresses expression evaluation
{
  echo 'locals {'
  echo '  env    = "production"'
  echo '  region = "us-east-1"'
  echo '  common_tags = {'
  echo '    environment = local.env'
  echo '    region      = local.region'
  echo '    managed_by  = "terraform"'
  echo '  }'
  for i in $(seq 0 $((NUM_LOCALS - 1))); do
    echo "  derived_${i} = \"val-\${local.env}-${i}\""
  done
  echo '}'
  echo ''
} >> "$OUTDIR/main.tf"

# Top-level terraform_data resources with cross-references
for i in $(seq 0 $((NUM_TOP_LEVEL - 1))); do
  prev_ref=""
  if [ "$i" -gt 0 ]; then
    prev_ref="    depends_on_prev = terraform_data.top_$((i - 1)).id"
  fi
  cat >> "$OUTDIR/main.tf" <<EOF

resource "terraform_data" "top_${i}" {
  input = {
    name   = "top-resource-${i}-\${local.env}"
    index  = "${i}"
    region = local.region
    tag    = local.derived_$((i % NUM_LOCALS))
${prev_ref}
  }
}
EOF
done

# Count-based resources — reference a fixed top resource to avoid HCL interpolation issues
cat >> "$OUTDIR/main.tf" <<EOF

resource "terraform_data" "counted" {
  count = ${NUM_TOP_LEVEL}
  input = {
    name  = "counted-\${count.index}"
    env   = local.env
    ref   = terraform_data.top_0.id
  }
}
EOF

# for_each resources
{
  echo ''
  echo 'resource "terraform_data" "each_item" {'
  echo "  for_each = toset([for i in range(${NUM_TOP_LEVEL}) : \"item-\${i}\"])"
  echo '  input = {'
  echo '    name = "each-${each.key}"'
  echo '    env  = local.env'
  echo '  }'
  echo '}'
} >> "$OUTDIR/main.tf"

# Module calls
for m in $(seq 0 $((NUM_MODULES - 1))); do
  cat >> "$OUTDIR/main.tf" <<EOF

module "service_${m}" {
  source      = "./modules/service"
  prefix      = "svc${m}-\${local.env}"
  count_val   = ${NUM_PER_MODULE}
  network_ref = terraform_data.top_$((m % NUM_TOP_LEVEL)).id
}
EOF
done

# Outputs that aggregate across modules (stresses output evaluation)
{
  echo ''
  echo 'output "all_service_ids" {'
  echo '  value = {'
  for m in $(seq 0 $((NUM_MODULES - 1))); do
    echo "    svc${m} = module.service_${m}.resource_ids"
  done
  echo '  }'
  echo '}'
  echo ''
  echo 'output "top_level_count" {'
  echo "  value = length(terraform_data.counted)"
  echo '}'
} >> "$OUTDIR/main.tf"

# --- modules/service/main.tf ---
mkdir -p "$OUTDIR/modules/service"
cat > "$OUTDIR/modules/service/main.tf" <<'EOF'
variable "prefix" {
  type = string
}

variable "count_val" {
  type = number
}

variable "network_ref" {
  type = string
}

locals {
  tags = {
    module  = var.prefix
    network = var.network_ref
  }
}

resource "terraform_data" "worker" {
  count = var.count_val
  input = {
    name       = "${var.prefix}-worker-${count.index}"
    network    = var.network_ref
    tags       = local.tags
    derived    = "${var.prefix}-derived-${count.index}"
  }
}

resource "terraform_data" "aggregator" {
  input = {
    name       = "${var.prefix}-aggregator"
    worker_ids = jsonencode([for w in terraform_data.worker : w.id])
  }
}

output "resource_ids" {
  value = terraform_data.worker[*].id
}

output "aggregator_id" {
  value = terraform_data.aggregator.id
}
EOF

echo "Generated config in $OUTDIR with ~$((NUM_TOP_LEVEL * 3 + NUM_MODULES * (NUM_PER_MODULE + 1))) resources"
