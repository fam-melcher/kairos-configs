#!/usr/bin/env bash
#
# build-iso.sh — build the generic installer ISO for the dev VM cluster.
#
# Produces build/iso/*.iso containing:
#   - iso/bootstrap.yaml as the baked cloud-config (runs the dispatcher)
#   - an ISO overlay with dispatch.sh, dispatch.env, a static sops binary
#     and the cluster age key
#
# WARNING: the resulting ISO embeds the private cluster age key. Treat the
# image as secret material — do not upload or redistribute it (ADR 0008).
#
# Usage:
#   scripts/build-iso.sh [branch]
#
#   branch  git branch the installed node fetches its configuration from
#           (default: currently checked-out branch)
#
# Environment overrides:
#   ARCH              target node architecture: amd64 or arm64 (default: amd64,
#                     the dev VM cluster runs on Hyper-V/Intel)
#   KAIROS_IMAGE      Kairos base image        (default: pinned below, per ARCH)
#   AURORABOOT_IMAGE  AuroraBoot builder image (default: pinned below)
#   AGE_KEY_FILE      cluster age private key  (default: ~/.config/sops/age/homelab-dev-cluster.txt)
#   SOPS_VERSION      static sops release bundled into the ISO

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "build-iso: FATAL: ${1}" >&2
    exit 1
}

ARCH="${ARCH:-amd64}"
case "${ARCH}" in
    amd64 | arm64) ;;
    *) fail "unsupported ARCH '${ARCH}' (amd64 or arm64)" ;;
esac

KAIROS_IMAGE="${KAIROS_IMAGE:-quay.io/kairos/ubuntu:24.04-standard-${ARCH}-generic-v3.7.2-k3s-v1.34.3-k3s3}"
AURORABOOT_IMAGE="${AURORABOOT_IMAGE:-quay.io/kairos/auroraboot:v0.25.2}"
AGE_KEY_FILE="${AGE_KEY_FILE:-${HOME}/.config/sops/age/homelab-dev-cluster.txt}"
SOPS_VERSION="${SOPS_VERSION:-v3.13.2}"
# The dispatcher and sops run inside the target's live system, not on the
# build host — the bundled binary must match ARCH, not the host.
sops_asset="sops-${SOPS_VERSION}.linux.${ARCH}"
sops_url="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}"

config_repo_url="https://raw.githubusercontent.com/fam-melcher/kairos-configs"

# Pick the first container engine whose daemon actually responds; a CLI on
# PATH without a running backend is useless for the build.
detect_engine() {
    local candidate

    for candidate in docker podman nerdctl; do
        command -v "${candidate}" > /dev/null || continue
        "${candidate}" info > /dev/null 2>&1 || continue
        echo "${candidate}"
        return 0
    done

    return 1
}

command -v curl > /dev/null || fail "curl not found"

engine="$(detect_engine)" \
    || fail "no running container engine found (tried: docker, podman, nerdctl)"
echo "build-iso: container engine: ${engine}"
[[ -r "${AGE_KEY_FILE}" ]] || fail "age key not readable: ${AGE_KEY_FILE}"

branch="${1:-$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD)}"
build_dir="${repo_root}/build"
overlay_dir="${build_dir}/overlay/dispatch"

# The overlay is fully generated — rebuild it from scratch on every run.
rm -rf "${build_dir}/overlay"
mkdir -p "${overlay_dir}"

# --- Static sops binary (cached in build/, checksum-verified) ---------------

if [[ ! -f "${build_dir}/${sops_asset}" ]]; then
    echo "build-iso: downloading ${sops_asset}"
    curl -fsSL "${sops_url}/${sops_asset}" -o "${build_dir}/${sops_asset}"
fi

checksums="$(curl -fsSL "${sops_url}/sops-${SOPS_VERSION}.checksums.txt")"
expected="$(echo "${checksums}" | grep " ${sops_asset}\$" | awk '{print $1}')"
[[ -n "${expected}" ]] || fail "no checksum for ${sops_asset} in release manifest"

actual="$(shasum -a 256 "${build_dir}/${sops_asset}" | awk '{print $1}')"
[[ "${actual}" == "${expected}" ]] || fail "checksum mismatch for ${sops_asset}"

# --- Assemble overlay and cloud-config ---------------------------------------

install -m 0755 "${repo_root}/iso/dispatch.sh" "${overlay_dir}/dispatch.sh"
install -m 0755 "${build_dir}/${sops_asset}" "${overlay_dir}/sops"
install -m 0600 "${AGE_KEY_FILE}" "${overlay_dir}/cluster.agekey"

cat > "${overlay_dir}/dispatch.env" <<EOF
CONFIG_BASE_URL="${config_repo_url}/${branch}"
EOF

cp "${repo_root}/iso/bootstrap.yaml" "${build_dir}/bootstrap.yaml"

# --- Build the ISO ------------------------------------------------------------

# The state dir must live in a named volume: AuroraBoot chowns files to
# root while dumping the rootfs, which fails on a macOS bind mount.
state_volume="kairos-iso-state"

echo "build-iso: image=${KAIROS_IMAGE}"
echo "build-iso: config branch=${branch}"

"${engine}" volume rm -f "${state_volume}" > /dev/null 2>&1 || true
"${engine}" volume create "${state_volume}" > /dev/null

"${engine}" run --rm --privileged \
    -v "${state_volume}:/state" \
    -v "${build_dir}:/input:ro" \
    "${AURORABOOT_IMAGE}" \
    --set "container_image=${KAIROS_IMAGE}" \
    --set "disable_http_server=true" \
    --set "disable_netboot=true" \
    --set "state_dir=/state" \
    --set "iso.overlay_iso=/input/overlay" \
    --cloud-config /input/bootstrap.yaml

mkdir -p "${build_dir}/iso"
"${engine}" run --rm \
    -v "${state_volume}:/state:ro" \
    -v "${build_dir}/iso:/out" \
    busybox sh -c 'cp /state/iso/*.iso /out/'
"${engine}" volume rm -f "${state_volume}" > /dev/null

echo
echo "build-iso: done — $(ls "${build_dir}"/iso/*.iso 2> /dev/null || echo 'no ISO found, check output above')"
echo "build-iso: WARNING: the ISO contains the private cluster age key."
