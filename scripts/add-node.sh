#!/usr/bin/env bash
#
# add-node.sh — scaffold the repository files for a new node.
#
# Usage:
#   scripts/add-node.sh <cluster> <uuid-or-node-id> [install-device]
#
#   cluster          name of a clusters/<name>/ directory (e.g. k8s-prod)
#   uuid-or-node-id  full product UUID, its first segment, or node-<id>
#   install-device   target disk (default: /dev/sda)
#
# Creates clusters/<cluster>/nodes/node-<id>/ with the node fragment and
# fragments.list from the templates. Refuses to overwrite an existing node
# directory; refuses unknown clusters (create those with add-cluster.sh).
#
# There is no role argument: whether a node joins the cluster or
# initialises a new one is decided by the installer at install time
# (ADR 0011); node definitions carry permanent configuration only.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "add-node: FATAL: ${1}" >&2
    exit 1
}

available_clusters() {
    local dir
    for dir in "${repo_root}/clusters"/*/; do
        [[ -d "${dir}" ]] && printf '%s ' "$(basename "${dir}")"
    done
}

[[ $# -ge 2 ]] || fail "usage: add-node.sh <cluster> <uuid-or-node-id> [install-device] — available clusters: $(available_clusters)"

cluster="${1}"
raw="${2}"
device="${3:-/dev/sda}"

[[ -d "${repo_root}/clusters/${cluster}" ]] \
    || fail "unknown cluster '${cluster}' — available: $(available_clusters); create one with scripts/add-cluster.sh"

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
node_dir="${repo_root}/clusters/${cluster}/nodes/${node_id}"

[[ ! -e "${node_dir}" ]] || fail "${node_dir} already exists"

mkdir -p "${node_dir}"

sed -e "s|@NODE_HOSTNAME@|${node_id}|g" \
    -e "s|@NODE_INSTALL_DEVICE@|${device}|g" \
    "${repo_root}/templates/20-node.yaml.tmpl" > "${node_dir}/20-${node_id}.yaml"

# Compose the fragment list instead of instantiating a template: base +
# every non-bootstrap fragment from the cluster's config dir and the
# shared cluster dir (ordered by numeric basename prefix) + the node
# fragment. New cluster fragments join future node lists automatically.
{
    echo "configs/base/00-base.yaml"
    for f in "${repo_root}/clusters/${cluster}/config/"*.yaml \
        "${repo_root}/configs/cluster/"*.yaml; do
        [[ -f "${f}" ]] || continue
        grep -q 'BOOTSTRAP-ROLE' "${f}" && continue
        printf '%s\t%s\n' "$(basename "${f}")" "${f#"${repo_root}/"}"
    done | sort | cut -f2
    echo "clusters/${cluster}/nodes/${node_id}/20-${node_id}.yaml"
} > "${node_dir}/fragments.list"

echo "add-node: created ${node_dir} (cluster: ${cluster}, device: ${device})"
echo "add-node: review the network section in 20-${node_id}.yaml, then commit and push."
