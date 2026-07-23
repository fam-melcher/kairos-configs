#!/usr/bin/env bash
#
# add-cluster.sh — scaffold everything a new cluster needs (ADR 0012).
#
# Usage:
#   scripts/add-cluster.sh <cluster-dns-name> <vip>
#
#   cluster-dns-name  FQDN of the cluster API, e.g. k8s-test.home.fam-melcher.net;
#                     the first segment becomes the directory name clusters/k8s-test/
#   vip               control plane VIP, e.g. 192.168.40.2
#
# Creates:
#   clusters/<name>/{config,nodes,secrets}   directory skeleton
#   clusters/<name>/config/*.yaml            rendered from templates/cluster/
#   .keys/<name>.agekey                      new cluster age key (never committed)
#   .sops.yaml                               appended creation rule for the cluster
#   clusters/<name>/secrets/k3s-token.sops.yaml  fresh token, sops-encrypted
#
# Refuses to touch anything that already exists. The plaintext token is
# piped straight into sops and never written to disk.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "add-cluster: FATAL: ${1}" >&2
    exit 1
}

for tool in age-keygen sops openssl; do
    command -v "${tool}" > /dev/null 2>&1 || fail "${tool} not found"
done

# The one GitOps repo for the whole fleet (ADR 0015) — fixed, not a
# per-cluster input.
gitops_repo="https://github.com/fam-melcher/kairos-gitops"

[[ $# -eq 2 ]] || fail "usage: add-cluster.sh <cluster-dns-name> <vip>"

dns_name="${1}"
vip="${2}"

[[ "${dns_name}" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] \
    || fail "'${dns_name}' is not a valid DNS name (lowercase FQDN required)"
[[ "${vip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || fail "'${vip}' is not a valid IPv4 address"

# The directory name is the first DNS segment — the naming invariant
# (clusters/<name> ⇔ <name>.<domain>) holds by construction and is
# enforced by scripts/validate-nodes.sh.
cluster="${dns_name%%.*}"
cluster_dir="${repo_root}/clusters/${cluster}"
key_file="${repo_root}/.keys/${cluster}.agekey"
engineer_key="${repo_root}/.keys/engineer.agekey"

[[ ! -e "${cluster_dir}" ]] || fail "${cluster_dir} already exists"
[[ ! -e "${key_file}" ]] || fail "${key_file} already exists"
[[ -r "${engineer_key}" ]] || fail "engineer key not readable: ${engineer_key}"

# --- Directory skeleton and config fragments ----------------------------------

mkdir -p "${cluster_dir}/config" "${cluster_dir}/nodes" "${cluster_dir}/secrets"

for tmpl in "${repo_root}/templates/cluster/"*.yaml.tmpl; do
    target="${cluster_dir}/config/$(basename "${tmpl}" .tmpl)"
    sed -e "s|@CLUSTER_DNS@|${dns_name}|g" \
        -e "s|@VIP@|${vip}|g" \
        -e "s|@GITOPS_REPO@|${gitops_repo}|g" \
        -e "s|@GITOPS_PATH@|clusters/${cluster}|g" \
        "${tmpl}" > "${target}"
    grep -q '@' "${target}" && fail "unresolved placeholder in ${target}"
done

echo "add-cluster: rendered config fragments for ${cluster} (VIP ${vip}, DNS ${dns_name})"

# --- Cluster age key ----------------------------------------------------------

age-keygen -o "${key_file}" 2> /dev/null
chmod 0600 "${key_file}"
cluster_pub="$(age-keygen -y "${key_file}")"
engineer_pub="$(age-keygen -y "${engineer_key}")"

echo "add-cluster: generated ${key_file}"
echo "add-cluster: cluster public key: ${cluster_pub}"

# --- SOPS creation rule -------------------------------------------------------

cat >> "${repo_root}/.sops.yaml" <<EOF
  - path_regex: clusters/${cluster}/secrets/.*\\.sops\\.yaml$
    age: >-
      ${engineer_pub},
      ${cluster_pub}
EOF

echo "add-cluster: appended creation rule to .sops.yaml"

# --- Fresh k3s token, encrypted without touching disk -------------------------

openssl rand -hex 32 \
    | sed -e 's/^/k3s_token: /' \
    | sops encrypt --input-type yaml --output-type yaml \
        --filename-override "clusters/${cluster}/secrets/k3s-token.sops.yaml" \
        /dev/stdin > "${cluster_dir}/secrets/k3s-token.sops.yaml"

echo "add-cluster: wrote clusters/${cluster}/secrets/k3s-token.sops.yaml"

# --- Next steps ---------------------------------------------------------------

echo
echo "add-cluster: cluster '${cluster}' scaffolded. Next steps:"
echo "  scripts/add-node.sh ${cluster} <uuid-or-node-id> [install-device]"
echo "  scripts/build-iso.sh <branch> ${cluster}"
echo "add-cluster: NOTE: .keys/${cluster}.agekey is local-only secret material — back it up."
