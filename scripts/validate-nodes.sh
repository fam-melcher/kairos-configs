#!/usr/bin/env bash
#
# validate-nodes.sh — enforce the repository invariants of ADR 0011.
#
# Node definitions describe permanent node configuration only. Bootstrap
# role selection is an installer-time decision and must never be encoded
# in node state. Concretely, for every clusters/*/nodes/*/fragments.list
# and the template:
#
#   1. every listed path must exist in the repository
#   2. no listed path may point to a fragment carrying the BOOTSTRAP-ROLE
#      marker (installer-selected fragments, ADR 0011)
#   3. the known bootstrap fragment names are rejected even if someone
#      strips the marker
#
# Additionally the cluster naming invariant (ADR 0012): every cluster
# directory name must equal the first segment of the DNS SAN in its
# config/12-cluster.yaml (clusters/k8s-prod ⇔ k8s-prod.home…).
#
# Exit code 0 = all invariants hold; 1 = violations (printed one per line).
#
# Usage: scripts/validate-nodes.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

marker="BOOTSTRAP-ROLE"
known_bootstrap_names=("10-server-init.yaml" "10-server-join.yaml" "13-join.yaml")

errors=0

violation() {
    echo "validate-nodes: ${1}" >&2
    errors=$((errors + 1))
}

lists=("${repo_root}"/clusters/*/nodes/*/fragments.list "${repo_root}/templates/fragments.list.tmpl")

for list in "${lists[@]}"; do
    [[ -f "${list}" ]] || continue
    rel_list="${list#"${repo_root}"/}"

    while IFS= read -r fragment; do
        [[ -n "${fragment}" ]] || continue

        # Template placeholders cannot be resolved to files; check names only.
        if [[ "${fragment}" != *@NODE_ID@* && "${fragment}" != *@CLUSTER@* \
            && ! -f "${repo_root}/${fragment}" ]]; then
            violation "${rel_list}: listed fragment does not exist: ${fragment}"
            continue
        fi

        for name in "${known_bootstrap_names[@]}"; do
            if [[ "$(basename "${fragment}")" == "${name}" ]]; then
                violation "${rel_list}: references bootstrap fragment ${fragment} — bootstrap roles are installer-selected (ADR 0011)"
            fi
        done

        if [[ "${fragment}" != *@NODE_ID@* && "${fragment}" != *@CLUSTER@* ]] \
            && grep -q "${marker}" "${repo_root}/${fragment}"; then
            violation "${rel_list}: references ${marker}-marked fragment ${fragment} — bootstrap roles are installer-selected (ADR 0011)"
        fi
    done < "${list}"
done

# --- Cluster naming invariant (ADR 0012) --------------------------------------

for cluster_dir in "${repo_root}"/clusters/*/; do
    [[ -d "${cluster_dir}" ]] || continue
    cluster="$(basename "${cluster_dir}")"
    cluster_yaml="${cluster_dir}config/12-cluster.yaml"

    if [[ ! -f "${cluster_yaml}" ]]; then
        violation "clusters/${cluster}: missing config/12-cluster.yaml"
        continue
    fi

    dns_name="$(sed -n 's/^ *- \([a-z0-9.-]*[a-z][a-z0-9.-]*\)$/\1/p' "${cluster_yaml}" | head -1)"
    if [[ -z "${dns_name}" ]]; then
        violation "clusters/${cluster}: no DNS name in tls-san of config/12-cluster.yaml"
    elif [[ "${dns_name%%.*}" != "${cluster}" ]]; then
        violation "clusters/${cluster}: directory name must equal the first DNS segment of its SAN (got '${dns_name}')"
    fi
done

if [[ "${errors}" -gt 0 ]]; then
    echo "validate-nodes: FAILED with ${errors} violation(s)" >&2
    exit 1
fi

echo "validate-nodes: OK"
