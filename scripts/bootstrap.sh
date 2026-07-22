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
ensure_dir "configs/roles"
ensure_dir "nodes"
ensure_dir "templates"
ensure_dir "secrets"
ensure_dir "scripts"
ensure_dir "docs/adr"

# --- Placeholder files -------------------------------------------------------

ensure_file "nodes/README.md" <<'EOF'
# Nodes

One directory per node, named exactly like the node's hostname. Each
directory contains the node-specific cloud-config fragment `20-<hostname>.yaml`.

Adding a node:

1. `mkdir nodes/<hostname>`
2. Copy `templates/20-node.yaml.tmpl` to `nodes/<hostname>/20-<hostname>.yaml`
3. Replace every `@VARIABLE@` placeholder; no placeholder may remain.
4. Open a pull request.

The node's full configuration is the ordered set of its permanent
fragments (`configs/base/00-base.yaml`, environment fragments,
`nodes/<hostname>/20-<hostname>.yaml`; see docs/adr/0004) plus the
bootstrap role selected by the installer at install time (docs/adr/0011).
Bootstrap roles must never appear in a node's fragment set.
EOF

ensure_file "secrets/README.md" <<'EOF'
# Secrets

Only SOPS-encrypted files (`*.sops.yaml`) may exist here; `.gitignore`
blocks everything else. Never commit plaintext secret material.

- Encrypt: `sops -e -i secrets/<name>.sops.yaml`
- Decrypt (to stdout only): `sops -d secrets/<name>.sops.yaml`
- Recipient changes: edit `.sops.yaml`, then `sops updatekeys secrets/*.sops.yaml`

Strategy and key handling: docs/adr/0005-secret-management.md.
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
