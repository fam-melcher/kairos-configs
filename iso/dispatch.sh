#!/bin/sh
#
# dispatch.sh — select and fetch this node's configuration during live boot.
#
# Shipped in the installer ISO overlay together with dispatch.env, a
# static sops binary and the cluster age key (ADR 0008). Derives the
# node ID from the machine's product UUID (ADR 0007), downloads the
# fragments listed in the node's fragments.list into /oem, decides the
# bootstrap role (join an existing cluster or initialise a new one,
# ADR 0011) and injects the decrypted K3s token. The Kairos auto-installer
# then proceeds with the staged configuration: install.auto comes from the
# fetched base fragment, so a machine whose dispatch fails stays in the
# live system.

set -eu

script_dir="$(cd "$(dirname "${0}")" && pwd)"
oem_dir="/oem"
uuid_file="/sys/class/dmi/id/product_uuid"

fail() {
    echo "dispatch: FATAL: ${1}" >&2
    exit 1
}

# hadron ships curl and openssl in the live system (verified against the
# image contents); sops and yq are bundled in the overlay.
command -v curl > /dev/null 2>&1 || fail "curl not found in live system"
command -v openssl > /dev/null 2>&1 || fail "openssl not found in live system"
[ -x "${script_dir}/yq" ] || fail "yq not found in overlay"

# probe <url> <output-file> — single silent attempt, used while polling for
# a configuration that may not exist yet (a 404 is expected, not an error).
probe() {
    curl -fsSL "${1}" -o "${2}" 2> /dev/null
}

# Full-screen status shown while waiting for the node's configuration to
# appear in the repository. Redrawn on every poll so the node ID and the
# machine facts an operator needs never scroll away.
status_screen() {
    _route="$(ip -4 route get 1.1.1.1 2> /dev/null | head -1)"
    _ip="$(echo "${_route}" | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
    _iface="$(echo "${_route}" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    _mac="$(cat "/sys/class/net/${_iface}/address" 2> /dev/null)"

    printf '\033[2J\033[H'
    echo "=============================================================="
    echo " Kairos installer — waiting for node configuration"
    echo "=============================================================="
    echo " Node ID      : ${node_id}"
    echo " Environment  : ${branch} / ${CLUSTER}"
    echo " Product UUID : ${uuid}"
    echo " IP address   : ${_ip:-none} (iface ${_iface:-?}, MAC ${_mac:-?})"
    echo " Disks        :"
    lsblk -dno NAME,SIZE,TYPE,MODEL 2> /dev/null | awk '$3 == "disk" {printf "   /dev/%-10s %8s  %s\n", $1, $2, $4}' \
        || sed -n '3,9p' /proc/partitions
    echo " Config URL   : ${list_url}"
    echo "--------------------------------------------------------------"
    echo " To provision this machine, run in the config repository:"
    echo "   scripts/add-node.sh ${CLUSTER} ${node_id} [install-device]"
    echo " then commit and push. Next check in 60s (poll #${poll})."
    echo "=============================================================="
}

# fetch <url> <output-file> — up to 3 attempts, tolerates slow DHCP/DNS.
fetch() {
    _attempt=1

    while [ "${_attempt}" -le 3 ]; do
        if curl -fsSL "${1}" -o "${2}"; then
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

# Provides CONFIG_BASE_URL and CLUSTER, written at ISO build time.
# shellcheck source=/dev/null
. "${script_dir}/dispatch.env"

[ -n "${CONFIG_BASE_URL:-}" ] || fail "CONFIG_BASE_URL not set in dispatch.env"
[ -n "${CLUSTER:-}" ] || fail "CLUSTER not set in dispatch.env"

# Branch = last path segment of the config URL; shown so an operator can
# tell at a glance which stage/cluster combination this ISO serves.
branch="${CONFIG_BASE_URL##*/}"

# Node ID = first 8 hex of sha256 over the lowercased product UUID
# (ADR 0010). Hashing the full UUID instead of taking its first segment
# avoids vendor-constant prefixes (Dell encodes "DELL" as 4c4c4544-…).
uuid="$(tr -d '[:space:]' < "${uuid_file}" | tr '[:upper:]' '[:lower:]')"
node_id="node-$(printf '%s' "${uuid}" | sha256sum | cut -c1-8)"
echo "dispatch: node id is ${node_id}"
echo "dispatch: using $(curl --version | head -1)"

# Advertise our identity where a headless operator already looks: name the
# live system setup-<id> and renew the DHCP lease so the switch/router UI
# shows which machine is waiting. Installed systems use node-<id>, so the
# setup- prefix unambiguously marks unprovisioned live boots.
setup_name="setup-${node_id#node-}"
hostnamectl set-hostname "${setup_name}" 2> /dev/null || hostname "${setup_name}" || true
# reconfigure (full DHCP cycle), not renew: networkd sends the hostname it
# cached at link setup on renewals, so the new name would never reach the
# DHCP server. Verified on Hyper-V: renew keeps the old lease name,
# reconfigure updates it and re-acquires the same address.
_iface="$(ip -4 route get 1.1.1.1 2> /dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
[ -z "${_iface}" ] || networkctl reconfigure "${_iface}" 2> /dev/null || true
sleep 3

# An unknown machine is not an error: keep polling so an operator can read
# the node id from the status screen, commit nodes/<id>/ to the repository
# (scripts/add-node.sh), and have the installation continue on the next
# poll — without another boot.
list_file="$(mktemp)"
list_url="${CONFIG_BASE_URL}/clusters/${CLUSTER}/nodes/${node_id}/fragments.list"
poll=1
until probe "${list_url}" "${list_file}"; do
    status_screen
    poll=$((poll + 1))
    sleep 60
done

mkdir -p "${oem_dir}"

yq="${script_dir}/yq"

# stage_cluster_values <values-yaml> — the cluster's 11-cluster.yaml is
# pure data (ADR 0013): a `values:` map, read with yq instead of ad-hoc
# text parsing. Every scalar entry becomes KEY=VALUE (dash -> underscore,
# uppercased) in a generated cloud-config fragment shipping
# /etc/kairos-cluster/cluster.env to the installed system. Lists and
# nested maps are skipped (extend the yq filter here when a consumer
# needs one). vip/dns_name are captured directly for the discovery step
# below — no re-parsing of our own generated output.
stage_cluster_values() {
    vip="$("${yq}" eval '.values.vip // ""' "${1}")"
    dns_name="$("${yq}" eval '.values.dns // ""' "${1}")"
    [ -n "${vip}" ] || fail "no values.vip in the cluster's 11-cluster.yaml"
    [ -n "${dns_name}" ] || fail "no values.dns in the cluster's 11-cluster.yaml"

    _env="$("${yq}" eval '
        .values
        | to_entries
        | map(select(.value | (tag == "!!str" or tag == "!!int" or tag == "!!bool" or tag == "!!float")))
        | map((.key | sub("-", "_") | upcase) + "=" + (.value | tostring))
        | .[]
    ' "${1}")"
    [ -n "${_env}" ] || fail "no scalar values found under values: in 11-cluster.yaml"

    # Build the generated fragment with yq itself instead of hand-indenting
    # text — only the "#cloud-config" marker line is not YAML (it is a
    # literal magic comment Kairos looks for) and stays a plain echo.
    {
        echo "#cloud-config"
        echo "# Generated by dispatch.sh from the cluster's 11-cluster.yaml values"
        echo "# file (ADR 0013). Do not edit on the node; change the values in the"
        echo "# repository and reinstall."
        CLUSTER_ENV_CONTENT="${_env}" "${yq}" eval --null-input '
            .stages.initramfs[0].name = "Cluster values"
            | .stages.initramfs[0].files[0].path = "/etc/kairos-cluster/cluster.env"
            | .stages.initramfs[0].files[0].permissions = 0644
            | .stages.initramfs[0].files[0].owner = 0
            | .stages.initramfs[0].files[0].group = 0
            | .stages.initramfs[0].files[0].content = strenv(CLUSTER_ENV_CONTENT)
        '
    } > "${oem_dir}/11-cluster.yaml"

    echo "dispatch: staged cluster values ($(printf '%s' "${_env}" | tr '\n' ' '))"
}

vip=""
dns_name=""

while IFS= read -r fragment; do
    [ -n "${fragment}" ] || continue
    echo "dispatch: fetching ${fragment}"
    if [ "$(basename "${fragment}")" = "11-cluster.yaml" ]; then
        values_file="$(mktemp)"
        fetch "${CONFIG_BASE_URL}/${fragment}" "${values_file}" \
            || fail "failed to fetch ${fragment}"
        stage_cluster_values "${values_file}"
        rm -f "${values_file}"
        continue
    fi
    fetch "${CONFIG_BASE_URL}/${fragment}" "${oem_dir}/$(basename "${fragment}")" \
        || fail "failed to fetch ${fragment}"
done < "${list_file}"
rm -f "${list_file}"

[ -n "${vip}" ] || fail "11-cluster.yaml not staged — fragments.list must list the cluster values fragment"

# --- Bootstrap role discovery (ADR 0011) -------------------------------
#
# fragments.list carries only permanent node configuration; whether this
# node joins the existing cluster or initialises a new one is decided
# here, at install time. The running cluster is authoritative for its own
# existence: probe the VIP and inspect the presented API server
# certificate. Three outcomes:
#   - answer with the expected SANs        -> join
#   - no answer after all attempts         -> genesis (cluster-init)
#   - answer with unexpected SANs          -> FATAL: something else owns
#     the VIP; initialising next to it would create a twin cluster.
#
# The probe parameters come from the cluster's single values fragment
# (11-cluster.yaml, already staged in /oem — ADR 0013), so no value
# exists twice anywhere.

join_fragment="configs/cluster/13-join.yaml"
join_file="$(mktemp)"
fetch "${CONFIG_BASE_URL}/${join_fragment}" "${join_file}" \
    || fail "failed to fetch ${join_fragment}"

echo "dispatch: probing for existing cluster at https://${vip}:6443 (expecting DNS SAN ${dns_name})"

# probe_cluster — one attempt. Returns 0 with san_list set when a TLS
# endpoint answered, 1 when nothing answered. An endpoint that answers
# but presents an unparseable certificate is treated as fatal, not as
# silence: silence is the only evidence that may lead to genesis.
probe_cluster() {
    _pem="$(curl -ksS --connect-timeout 4 --max-time 8 \
        -o /dev/null -w '%{certs}' "https://${vip}:6443/" 2> /dev/null)" || return 1
    [ -n "${_pem}" ] || return 1

    # First certificate in the chain is the serving certificate.
    san_list="$(printf '%s\n' "${_pem}" \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p
                  /-----END CERTIFICATE-----/q' \
        | openssl x509 -noout -ext subjectAltName 2> /dev/null)" \
        || fail "endpoint at ${vip}:6443 answered but its certificate is unreadable"
    return 0
}

vip_re="$(printf '%s' "${vip}" | sed 's/\./\\./g')"
dns_re="$(printf '%s' "${dns_name}" | sed 's/\./\\./g')"

attempts="${DISCOVERY_ATTEMPTS:-6}"
attempt=1
role_fragment=""
while [ "${attempt}" -le "${attempts}" ]; do
    if probe_cluster; then
        echo "${san_list}" | grep -Eq "IP Address:${vip_re}(,|\$)" \
            || fail "cluster at ${vip}:6443 lacks IP SAN ${vip} — refusing to join or initialise. SANs: ${san_list}"
        echo "${san_list}" | grep -Eq "DNS:${dns_re}(,|\$)" \
            || fail "cluster at ${vip}:6443 lacks DNS SAN ${dns_name} — refusing to join or initialise. SANs: ${san_list}"
        echo "dispatch: join — certificate SANs matched on attempt ${attempt}/${attempts}"
        role_fragment="configs/roles/10-server-join.yaml"
        mv "${join_file}" "${oem_dir}/$(basename "${join_fragment}")"
        break
    fi
    echo "dispatch: no cluster answer on attempt ${attempt}/${attempts}"
    attempt=$((attempt + 1))
    [ "${attempt}" -le "${attempts}" ] && sleep 5
done

if [ -z "${role_fragment}" ]; then
    echo "dispatch: genesis — no cluster answered after ${attempts} attempts, initialising a new cluster"
    role_fragment="configs/roles/10-server-init.yaml"
    rm -f "${join_file}"
fi

echo "dispatch: fetching ${role_fragment}"
fetch "${CONFIG_BASE_URL}/${role_fragment}" "${oem_dir}/$(basename "${role_fragment}")" \
    || fail "failed to fetch ${role_fragment}"
# --- end bootstrap role discovery --------------------------------------

# Inject the cluster token: fetch the encrypted secret, decrypt it with the
# cluster age key from the overlay, stage it as the last fragment.
token_file="$(mktemp)"
fetch "${CONFIG_BASE_URL}/clusters/${CLUSTER}/secrets/k3s-token.sops.yaml" "${token_file}" \
    || fail "failed to fetch k3s token secret"

token="$(SOPS_AGE_KEY_FILE="${script_dir}/cluster.agekey" \
    "${script_dir}/sops" -d --input-type yaml --output-type yaml \
    --extract '["k3s_token"]' "${token_file}")" \
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

# Hand the installation over to a dedicated transient unit instead of
# blocking this yip stage: steps of a stage run interleaved, so blocking
# here stalls the datasource sentinel cleanup and the boot chain behind
# cos-setup-network. Before that:
# - stop the interactive installer services so nothing races us to the disk
# - clear the stale datasource sentinel (no datasource exists on this boot
#   path; the installer would otherwise wait 5 minutes for it)
echo "dispatch: starting installation"
systemctl stop kairos-webui.service kairos-installer.service 2> /dev/null || true
rm -f /run/.userdata_load
exec systemd-run --unit=dispatch-install \
    --property=StandardOutput=journal+console \
    --property=StandardError=journal+console \
    /usr/bin/kairos-agent install
