#!/usr/bin/env bash
#
# validate-nodes.sh — enforce the repository invariants of ADR 0011.
#
# Node definitions describe permanent node configuration only. Bootstrap
# role selection is an installer-time decision and must never be encoded
# in node state. Concretely, for every nodes/*/fragments.list and the
# template:
#
#   1. every listed path must exist in the repository
#   2. no listed path may point to a fragment carrying the BOOTSTRAP-ROLE
#      marker (installer-selected fragments, ADR 0011)
#   3. the known bootstrap fragment names are rejected even if someone
#      strips the marker
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

lists=("${repo_root}"/nodes/*/fragments.list "${repo_root}/templates/fragments.list.tmpl")

for list in "${lists[@]}"; do
    [[ -f "${list}" ]] || continue
    rel_list="${list#"${repo_root}"/}"

    while IFS= read -r fragment; do
        [[ -n "${fragment}" ]] || continue

        # Template placeholders cannot be resolved to files; check names only.
        if [[ "${fragment}" != *@NODE_ID@* && ! -f "${repo_root}/${fragment}" ]]; then
            violation "${rel_list}: listed fragment does not exist: ${fragment}"
            continue
        fi

        for name in "${known_bootstrap_names[@]}"; do
            if [[ "$(basename "${fragment}")" == "${name}" ]]; then
                violation "${rel_list}: references bootstrap fragment ${fragment} — bootstrap roles are installer-selected (ADR 0011)"
            fi
        done

        if [[ "${fragment}" != *@NODE_ID@* ]] \
            && grep -q "${marker}" "${repo_root}/${fragment}"; then
            violation "${rel_list}: references ${marker}-marked fragment ${fragment} — bootstrap roles are installer-selected (ADR 0011)"
        fi
    done < "${list}"
done

if [[ "${errors}" -gt 0 ]]; then
    echo "validate-nodes: FAILED with ${errors} violation(s)" >&2
    exit 1
fi

echo "validate-nodes: OK"
