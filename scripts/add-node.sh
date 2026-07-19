#!/usr/bin/env bash
#
# add-node.sh — scaffold the repository files for a new node.
#
# Usage:
#   scripts/add-node.sh <uuid-or-node-id> [join|init] [install-device]
#
#   uuid-or-node-id  full product UUID, its first segment, or node-<id>
#   role             join (default) or init (first server of a new cluster)
#   install-device   target disk (default: /dev/sda)
#
# Creates nodes/node-<id>/ with the node fragment and fragments.list from
# the templates. Refuses to overwrite an existing node directory.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "add-node: FATAL: ${1}" >&2
    exit 1
}

[[ $# -ge 1 ]] || fail "usage: add-node.sh <uuid-or-node-id> [join|init] [install-device]"

raw="${1}"
role="${2:-join}"
device="${3:-/dev/sda}"

case "${role}" in
    join | init) ;;
    *) fail "role must be 'join' or 'init', got '${role}'" ;;
esac

# Normalize the install device: accept bare names like "sda" or "nvme0n1".
[[ "${device}" == /dev/* ]] || device="/dev/${device}"
[[ "${device}" =~ ^/dev/[a-zA-Z0-9_/-]+$ ]] || fail "invalid install device '${device}'"

# Accept a full product UUID (hashed like the dispatcher does, ADR 0010)
# or a ready-made id in any form an operator encounters it: node-<8hex>,
# setup-<8hex> (DHCP name of a waiting installer), or the bare 8 hex
# characters. Since the hash scheme, a bare 8-hex string is unambiguous.
sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum
    else
        shasum -a 256
    fi
}

normalized="$(echo "${raw}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
normalized="${normalized#node-}"
normalized="${normalized#setup-}"

if [[ "${normalized}" =~ ^[0-9a-f]{8}$ ]]; then
    node_id="node-${normalized}"
elif [[ "${normalized}" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then
    node_id="node-$(printf '%s' "${normalized}" | sha256 | cut -c1-8)"
else
    fail "'${raw}' is neither a full product UUID nor an 8-hex node id"
fi
node_dir="${repo_root}/nodes/${node_id}"

[[ ! -e "${node_dir}" ]] || fail "${node_dir} already exists"

mkdir -p "${node_dir}"

sed -e "s|@NODE_HOSTNAME@|${node_id}|g" \
    -e "s|@NODE_INSTALL_DEVICE@|${device}|g" \
    "${repo_root}/templates/20-node.yaml.tmpl" > "${node_dir}/20-${node_id}.yaml"

# init nodes must not carry the join target fragment (configs/env/13-join.yaml).
if [[ "${role}" == "init" ]]; then
    sed -e "s|@NODE_ID@|${node_id}|g" \
        -e "s|10-server-join|10-server-init|g" \
        -e "\|configs/env/13-join.yaml|d" \
        "${repo_root}/templates/fragments.list.tmpl" > "${node_dir}/fragments.list"
else
    sed -e "s|@NODE_ID@|${node_id}|g" \
        "${repo_root}/templates/fragments.list.tmpl" > "${node_dir}/fragments.list"
fi

echo "add-node: created ${node_dir} (role: ${role}, device: ${device})"
echo "add-node: review the network section in 20-${node_id}.yaml, then commit and push."
