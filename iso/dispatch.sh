#!/bin/sh
#
# dispatch.sh — select and fetch this node's configuration during live boot.
#
# Shipped in the installer ISO overlay together with dispatch.env, a static
# sops binary and the cluster age key (ADR 0008). Derives the node ID from
# the machine's product UUID (ADR 0007), downloads the fragments listed in
# the node's fragments.list into /oem and injects the decrypted K3s token.
# The Kairos auto-installer then proceeds with the staged configuration.
#
# Fails loudly: a machine without a matching nodes/<id>/ directory stays in
# the live system and does not install.

set -eu

script_dir="$(cd "$(dirname "${0}")" && pwd)"
oem_dir="/oem"
uuid_file="/sys/class/dmi/id/product_uuid"

fail() {
    echo "dispatch: FATAL: ${1}" >&2
    exit 1
}

[ -r "${uuid_file}" ] || fail "cannot read ${uuid_file}"
[ -r "${script_dir}/dispatch.env" ] || fail "dispatch.env missing from overlay"

# Provides CONFIG_BASE_URL, written at ISO build time.
. "${script_dir}/dispatch.env"

[ -n "${CONFIG_BASE_URL:-}" ] || fail "CONFIG_BASE_URL not set in dispatch.env"

node_id="node-$(cut -d- -f1 "${uuid_file}" | tr '[:upper:]' '[:lower:]')"
echo "dispatch: node id is ${node_id}"

list_url="${CONFIG_BASE_URL}/nodes/${node_id}/fragments.list"
fragments="$(curl -fsSL "${list_url}")" \
    || fail "no configuration for ${node_id} (${list_url})"

mkdir -p "${oem_dir}"

for fragment in ${fragments}; do
    echo "dispatch: fetching ${fragment}"
    curl -fsSL "${CONFIG_BASE_URL}/${fragment}" \
        -o "${oem_dir}/$(basename "${fragment}")" \
        || fail "failed to fetch ${fragment}"
done

# Inject the cluster token: fetch the encrypted secret, decrypt it with the
# cluster age key from the overlay, stage it as the last fragment.
token_file="$(mktemp)"
curl -fsSL "${CONFIG_BASE_URL}/secrets/k3s-token.sops.yaml" -o "${token_file}" \
    || fail "failed to fetch k3s token secret"

token="$(SOPS_AGE_KEY_FILE="${script_dir}/cluster.agekey" \
    "${script_dir}/sops" -d --extract '["k3s_token"]' "${token_file}")" \
    || fail "failed to decrypt k3s token"
rm -f "${token_file}"

umask 077
cat > "${oem_dir}/30-k3s-token.yaml" <<EOF
#cloud-config
k3s:
  env:
    K3S_TOKEN: "${token}"
EOF

echo "dispatch: configuration for ${node_id} staged in ${oem_dir}"
