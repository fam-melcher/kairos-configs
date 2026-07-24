#!/usr/bin/env bash
#
# render-base-fragment.sh — embed configs/base/kairos-status.sh verbatim
# into the "content: |" block of configs/base/00-base.yaml.
#
# Kairos cloud-config has no file-include directive, so the script text
# must live inline in the fragment — but hand-copying it there would put a
# shell script outside shellcheck's reach and out of sync with its source
# the moment either one gets edited alone. This script is the only thing
# allowed to touch that block: edit configs/base/kairos-status.sh, then run
# this. CI (validate.yaml) re-runs it and fails the PR on any diff.

set -euo pipefail

repo_root="$(cd "$(dirname "${0}")/.." && pwd)"
src="${repo_root}/configs/base/kairos-status.sh"
dst="${repo_root}/configs/base/00-base.yaml"

anchor='        - path: /usr/local/sbin/kairos-status'
marker_start='          content: |'
marker_end='        - path: /etc/systemd/system/kairos-status.service'

anchor_line="$(grep -n -F "${anchor}" "${dst}" | head -1 | cut -d: -f1)" || true
[ -n "${anchor_line}" ] || { echo "render-base-fragment: anchor not found in ${dst}" >&2; exit 1; }

start_line="$(tail -n "+$((anchor_line + 1))" "${dst}" | grep -n -F "${marker_start}" | head -1 | cut -d: -f1)" || true
[ -n "${start_line}" ] || { echo "render-base-fragment: start marker not found after anchor in ${dst}" >&2; exit 1; }
start_line=$((anchor_line + start_line))

end_line="$(tail -n "+$((start_line + 1))" "${dst}" | grep -n -F "${marker_end}" | head -1 | cut -d: -f1)" || true
[ -n "${end_line}" ] || { echo "render-base-fragment: end marker not found in ${dst}" >&2; exit 1; }
end_line=$((start_line + end_line))

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

{
    head -n "${start_line}" "${dst}"
    sed 's/^/            /' "${src}"
    tail -n "+${end_line}" "${dst}"
} > "${tmp}"

mv "${tmp}" "${dst}"
trap - EXIT
echo "render-base-fragment: embedded $(basename "${src}") into $(basename "${dst}")"
