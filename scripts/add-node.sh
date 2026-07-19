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

# Normalize: strip a node- prefix, take the first dash-separated segment,
# lowercase — the same derivation the dispatcher uses (ADR 0007).
id="${raw#node-}"
id="${id%%-*}"
id="$(echo "${id}" | tr '[:upper:]' '[:lower:]')"

[[ "${id}" =~ ^[0-9a-f]{8}$ ]] || fail "'${raw}' does not yield an 8-hex node id (got '${id}')"

node_id="node-${id}"
node_dir="${repo_root}/nodes/${node_id}"

[[ ! -e "${node_dir}" ]] || fail "${node_dir} already exists"

mkdir -p "${node_dir}"

sed -e "s|@NODE_HOSTNAME@|${node_id}|g" \
    -e "s|@NODE_INSTALL_DEVICE@|${device}|g" \
    "${repo_root}/templates/20-node.yaml.tmpl" > "${node_dir}/20-${node_id}.yaml"

sed -e "s|@NODE_ID@|${node_id}|g" \
    -e "s|10-server-join|10-server-${role}|g" \
    "${repo_root}/templates/fragments.list.tmpl" > "${node_dir}/fragments.list"

echo "add-node: created ${node_dir} (role: ${role}, device: ${device})"
echo "add-node: review the network section in 20-${node_id}.yaml, then commit and push."
