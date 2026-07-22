#!/usr/bin/env bash
#
# bootstrap.sh — create or repair the repository skeleton.
#
# Idempotent: safe to run any number of times. Creates missing directories
# and placeholder files, never overwrites existing content.
#
# Usage:
#   scripts/bootstrap.sh
#
# Requirements: bash, coreutils. No other dependencies.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

created=0
skipped=0

ensure_dir() {
    local dir="${repo_root}/${1}"

    if [[ -d "${dir}" ]]; then
        skipped=$((skipped + 1))
        return 0
    fi

    mkdir -p "${dir}"
    echo "created  ${1}/"
    created=$((created + 1))
}

# ensure_file <path> ; content read from stdin. Existing files are left as-is.
ensure_file() {
    local file="${repo_root}/${1}"

    if [[ -e "${file}" ]]; then
        skipped=$((skipped + 1))
        cat > /dev/null   # drain stdin
        return 0
    fi

    mkdir -p "$(dirname "${file}")"
    cat > "${file}"
    echo "created  ${1}"
    created=$((created + 1))
}

# --- Directory skeleton ------------------------------------------------------

ensure_dir "configs/base"
ensure_dir "configs/cluster"
ensure_dir "configs/roles"
ensure_dir "clusters"
ensure_dir "templates/cluster"
ensure_dir "scripts"
ensure_dir "docs/adr"

# --- Placeholder files -------------------------------------------------------

ensure_file "clusters/README.md" <<'EOF'
# Clusters

One directory per cluster (ADR 0012), named after the first segment of the
cluster's DNS name: `clusters/<name>/{config,nodes,secrets}`. Create new
clusters with `scripts/add-cluster.sh <dns-name> <vip>` — it scaffolds the
directories, renders the config fragments, generates the age key, appends
the sops rule, and writes a fresh encrypted k3s token.

Secrets: only SOPS-encrypted files (`*.sops.yaml`) may exist under
`clusters/<name>/secrets/`; `.gitignore` blocks everything else. Never
commit plaintext secret material (docs/adr/0005-secret-management.md).

Nodes live under `clusters/<name>/nodes/`; add them with
`scripts/add-node.sh <cluster> <uuid>` (see the per-node README).
EOF

ensure_file "templates/20-node.yaml.tmpl" <<'EOF'
#cloud-config
# Node-specific fragment. Copy to nodes/<hostname>/20-<hostname>.yaml and
# replace every @VARIABLE@ placeholder (grep '@' must return nothing).

hostname: "@NODE_HOSTNAME@"

# Uncomment and adjust for static addressing; omit for DHCP.
# stages:
#   initramfs:
#     - name: "Static network configuration"
#       commands:
#         - nmcli con mod "Wired connection 1" ipv4.method manual \
#             ipv4.addresses @NODE_IP@/@NODE_PREFIX@ \
#             ipv4.gateway @NODE_GATEWAY@ ipv4.dns "@NODE_DNS@"

install:
  # Target disk for this machine, e.g. /dev/nvme0n1 or /dev/sda.
  device: "@NODE_INSTALL_DEVICE@"
EOF

ensure_file ".sops.yaml" <<'EOF'
# SOPS configuration — see docs/adr/0005-secret-management.md.
#
# Encryption is not active yet. To enable:
#   1. Generate a key pair:  age-keygen -o .keys/engineer.agekey
#   2. Enter the *public* key below and remove the comment markers.
#
# creation_rules:
#   - path_regex: secrets/.*\.sops\.yaml$
#     age: age1REPLACE_WITH_PUBLIC_KEY
EOF

# --- Summary -----------------------------------------------------------------

echo "bootstrap complete: ${created} created, ${skipped} already present"
