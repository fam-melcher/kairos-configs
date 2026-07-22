#!/usr/bin/env bash
#
# build-iso.sh — build the generic installer ISO for one cluster.
#
# Branches are stages, directories are environments (ADR 0012):
#   main  -> live configuration; the target cluster must be given explicitly
#   dev   -> staging; defaults to the k8s-dev cluster, any cluster overridable
#            (e.g. `build-iso.sh dev k8s-prod` tests prod config before merge)
# Builds from any other branch are refused: an ISO must never point at a
# branch that disappears after a merge.
#
# Produces build/iso/kairos-<version>-<arch>-<distro>-<branch>-<cluster>.iso:
#   - iso/bootstrap.yaml as the baked cloud-config
#   - a rootfs overlay with the dispatch trigger (/system/oem)
#   - an ISO overlay with dispatch.sh, dispatch.env, a static sops binary
#     and the cluster's age key
#
# Only tools missing from the hadron image are bundled (verified against
# the image contents): curl ships with hadron, sops does not.
#
# WARNING: the resulting ISO embeds the private cluster age key. Treat the
# image as secret material (ADR 0008).
#
# Usage:
#   scripts/build-iso.sh <branch> [cluster]
#
#   branch   main or dev
#   cluster  name of a clusters/<name>/ directory; required for main,
#            defaults to k8s-dev for dev
#
# Environment overrides:
#   ARCH              target architecture: amd64 or arm64 (default: amd64)
#   KAIROS_VERSION    Kairos release (default below), used for image + ISO name
#   K8S_VERSION       bundled k3s version tag
#   HADRON_VERSION    hadron flavor release
#   KAIROS_IMAGE      full image override (skips construction from the above)
#   AURORABOOT_IMAGE  AuroraBoot builder image
#   AGE_KEY_FILE      cluster age key (default: .keys/<cluster>.agekey)
#   SOPS_VERSION      sops release to bundle (default: latest — resolved at
#                     build time so fixes arrive automatically; pin for
#                     reproducible builds)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "build-iso: FATAL: ${1}" >&2
    exit 1
}

# --- Branch (stage) and cluster (environment), ADR 0012 -----------------------

[[ $# -ge 1 ]] || fail "usage: build-iso.sh <branch> [cluster]"

branch="${1}"
cluster="${2:-}"

case "${branch}" in
    main)
        [[ -n "${cluster}" ]] \
            || fail "main builds require an explicit cluster (usage: build-iso.sh main <cluster>)"
        ;;
    dev)
        cluster="${cluster:-k8s-dev}"
        ;;
    *) fail "ISO builds are only supported from main or dev (got '${branch}')" ;;
esac

available_clusters() {
    local dir
    for dir in "${repo_root}/clusters"/*/; do
        [[ -d "${dir}" ]] && printf '%s ' "$(basename "${dir}")"
    done
}

[[ -d "${repo_root}/clusters/${cluster}" ]] \
    || fail "unknown cluster '${cluster}' — available: $(available_clusters)"

# --- Versions (single source for image tag and ISO name) ----------------------

ARCH="${ARCH:-amd64}"
case "${ARCH}" in
    amd64 | arm64) ;;
    *) fail "unsupported ARCH '${ARCH}' (amd64 or arm64)" ;;
esac

KAIROS_VERSION="${KAIROS_VERSION:-4.1.2}"
K8S_DISTRO="k3s"
K8S_VERSION="${K8S_VERSION:-v1.35.5-k3s1}"
HADRON_VERSION="${HADRON_VERSION:-v0.4.0}"

# Kairos v4 publishes prebuilt images as the "hadron" flavor; the ubuntu
# flavor repositories are no longer updated by the release pipeline.
KAIROS_IMAGE="${KAIROS_IMAGE:-quay.io/kairos/hadron:${HADRON_VERSION}-standard-${ARCH}-generic-v${KAIROS_VERSION}-${K8S_DISTRO}-${K8S_VERSION}}"
AURORABOOT_IMAGE="${AURORABOOT_IMAGE:-quay.io/kairos/auroraboot:v0.25.2}"
AGE_KEY_FILE="${AGE_KEY_FILE:-${repo_root}/.keys/${cluster}.agekey}"
SOPS_VERSION="${SOPS_VERSION:-latest}"

iso_name="kairos-${KAIROS_VERSION}-${ARCH}-${K8S_DISTRO}-${branch}-${cluster}.iso"
config_repo_url="https://raw.githubusercontent.com/fam-melcher/kairos-configs"

# --- Preconditions ------------------------------------------------------------

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
[[ -r "${AGE_KEY_FILE}" ]] || fail "age key not readable: ${AGE_KEY_FILE}"

engine="$(detect_engine)" \
    || fail "no running container engine found (tried: docker, podman, nerdctl)"
echo "build-iso: container engine: ${engine}"

build_dir="${repo_root}/build"
overlay_dir="${build_dir}/overlay/dispatch"

# The overlay is fully generated — rebuild it from scratch on every run.
rm -rf "${build_dir}/overlay"
mkdir -p "${overlay_dir}"

# --- Static sops binary (cached in build/, checksum-verified) -----------------

if [[ "${SOPS_VERSION}" == "latest" ]]; then
    SOPS_VERSION="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    [[ -n "${SOPS_VERSION}" ]] || fail "could not resolve latest sops release"
fi
echo "build-iso: bundling sops ${SOPS_VERSION}"

# The dispatcher and its binaries run inside the target's live system, not
# on the build host — the bundled binaries must match ARCH, not the host.
sops_asset="sops-${SOPS_VERSION}.linux.${ARCH}"
sops_url="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}"

if [[ ! -f "${build_dir}/${sops_asset}" ]]; then
    echo "build-iso: downloading ${sops_asset}"
    curl -fsSL "${sops_url}/${sops_asset}" -o "${build_dir}/${sops_asset}"
fi

checksums="$(curl -fsSL "${sops_url}/sops-${SOPS_VERSION}.checksums.txt")"
expected="$(echo "${checksums}" | grep " ${sops_asset}\$" | awk '{print $1}')"
[[ -n "${expected}" ]] || fail "no checksum for ${sops_asset} in release manifest"

actual="$(shasum -a 256 "${build_dir}/${sops_asset}" | awk '{print $1}')"
[[ "${actual}" == "${expected}" ]] || fail "checksum mismatch for ${sops_asset}"

# --- Assemble overlays and cloud-config ---------------------------------------

install -m 0755 "${repo_root}/iso/dispatch.sh" "${overlay_dir}/dispatch.sh"
install -m 0755 "${build_dir}/${sops_asset}" "${overlay_dir}/sops"
install -m 0600 "${AGE_KEY_FILE}" "${overlay_dir}/cluster.agekey"

cat > "${overlay_dir}/dispatch.env" <<EOF
CONFIG_BASE_URL="${config_repo_url}/${branch}"
CLUSTER="${cluster}"
EOF

cp "${repo_root}/iso/bootstrap.yaml" "${build_dir}/bootstrap.yaml"

# The dispatch trigger must be a real file in a yip scan directory; stages
# inside the baked cloud config are not executed in the live system.
rm -rf "${build_dir}/rootfs-overlay"
mkdir -p "${build_dir}/rootfs-overlay/system/oem"
cp "${repo_root}/iso/91-dispatch.yaml" "${build_dir}/rootfs-overlay/system/oem/91-dispatch.yaml"

# --- Build the ISO ------------------------------------------------------------

# The state dir must live in a named volume: AuroraBoot chowns files to
# root while dumping the rootfs, which fails on a macOS bind mount.
state_volume="kairos-iso-state"

echo "build-iso: image=${KAIROS_IMAGE}"
echo "build-iso: cluster=${cluster} (config branch: ${branch})"
echo "build-iso: output=${iso_name}"

"${engine}" volume rm -f "${state_volume}" > /dev/null 2>&1 || true
"${engine}" volume create "${state_volume}" > /dev/null

"${engine}" run --rm --privileged \
    -v "${state_volume}:/state" \
    -v "${build_dir}:/input:ro" \
    "${AURORABOOT_IMAGE}" \
    --set "container_image=${KAIROS_IMAGE}" \
    --set "arch=${ARCH}" \
    --set "disable_http_server=true" \
    --set "disable_netboot=true" \
    --set "state_dir=/state" \
    --set "iso.overlay_iso=/input/overlay" \
    --set "iso.overlay_rootfs=/input/rootfs-overlay" \
    --cloud-config /input/bootstrap.yaml

mkdir -p "${build_dir}/iso"
"${engine}" run --rm \
    -v "${state_volume}:/state:ro" \
    -v "${build_dir}/iso:/out" \
    busybox sh -c "cp /state/*.iso /out/${iso_name}"
"${engine}" volume rm -f "${state_volume}" > /dev/null

(cd "${build_dir}/iso" && shasum -a 256 "${iso_name}" > "${iso_name}.sha256")

echo
echo "build-iso: done — ${build_dir}/iso/${iso_name}"
echo "build-iso: WARNING: the ISO contains the private ${cluster} cluster age key."
