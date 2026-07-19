#!/bin/sh
#
# dispatch.sh — select and fetch this node's configuration during live boot.
#
# Shipped in the installer ISO overlay together with dispatch.env, static
# sops and curl binaries and the cluster age key (ADR 0008). Derives the
# node ID from the machine's product UUID (ADR 0007), downloads the
# fragments listed in the node's fragments.list into /oem and injects the
# decrypted K3s token. The Kairos auto-installer then proceeds with the
# staged configuration: install.auto comes from the fetched base fragment,
# so a machine whose dispatch fails stays in the live system.

set -eu

script_dir="$(cd "$(dirname "${0}")" && pwd)"
oem_dir="/oem"
uuid_file="/sys/class/dmi/id/product_uuid"

fail() {
    echo "dispatch: FATAL: ${1}" >&2
    exit 1
}

# Minimal live systems (hadron) may not ship curl; fall back to the bundled
# static binary.
curl_bin="curl"
command -v curl > /dev/null 2>&1 || curl_bin="${script_dir}/curl"

# fetch <url> <output-file> — up to 3 attempts, tolerates slow DHCP/DNS.
fetch() {
    _attempt=1

    while [ "${_attempt}" -le 3 ]; do
        if "${curl_bin}" -fsSL "${1}" -o "${2}"; then
            return 0
        fi
        echo "dispatch: fetch attempt ${_attempt}/3 failed: ${1}" >&2
        _attempt=$((_attempt + 1))
        sleep 5
    done

    return 1
}

[ -r "${uuid_file}" ] || fail "cannot read ${uuid_file}"
[ -r "${script_dir}/dispatch.env" ] || fail "dispatch.env missing from overlay"

# Provides CONFIG_BASE_URL, written at ISO build time.
. "${script_dir}/dispatch.env"

[ -n "${CONFIG_BASE_URL:-}" ] || fail "CONFIG_BASE_URL not set in dispatch.env"

node_id="node-$(cut -d- -f1 "${uuid_file}" | tr '[:upper:]' '[:lower:]')"
echo "dispatch: node id is ${node_id}"
echo "dispatch: using $(${curl_bin} --version | head -1)"

list_file="$(mktemp)"
fetch "${CONFIG_BASE_URL}/nodes/${node_id}/fragments.list" "${list_file}" \
    || fail "no configuration for ${node_id}"

mkdir -p "${oem_dir}"

while IFS= read -r fragment; do
    [ -n "${fragment}" ] || continue
    echo "dispatch: fetching ${fragment}"
    fetch "${CONFIG_BASE_URL}/${fragment}" "${oem_dir}/$(basename "${fragment}")" \
        || fail "failed to fetch ${fragment}"
done < "${list_file}"
rm -f "${list_file}"

# Inject the cluster token: fetch the encrypted secret, decrypt it with the
# cluster age key from the overlay, stage it as the last fragment.
token_file="$(mktemp)"
fetch "${CONFIG_BASE_URL}/secrets/k3s-token.sops.yaml" "${token_file}" \
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

# Trigger the installation ourselves instead of relying on the installer
# service having started after the staging above (its config snapshot is
# taken at service start — a race we lose on fast boots). kairos-agent
# re-scans all config sources including /oem at this point.
echo "dispatch: starting installation"
exec kairos-agent install
