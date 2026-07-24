#!/bin/sh
# Status screen on tty1 (ADR pending): loops forever, redrawing cluster and
# node facts every ~5s, Talos-dashboard style (bar graphs, node health,
# resource usage) instead of a plain login prompt nobody can use. Canonical
# source — configs/base/00-base.yaml embeds this file verbatim via
# scripts/render-base-fragment.sh; edit here, then run that script, never
# the other way around.
#
# hadron ships no `uptime`/`free` binaries (verified via ssh against
# node-9c271a15, a live k8s-prod node) — /proc/uptime and /proc/meminfo are
# parsed by hand instead. `df` and `nproc` are present and used as-is.
set -eu

env_file="/etc/kairos-cluster/cluster.env"
hostname="$(hostname)"

# bar <percent> — renders a 20-cell Talos-style usage bar, e.g. "[====----------------]  20%".
bar() {
    _pct="$1"
    [ "${_pct}" -le 100 ] || _pct=100
    _width=20
    _filled=$((_pct * _width / 100))
    _i=0
    _out=""
    while [ "${_i}" -lt "${_width}" ]; do
        if [ "${_i}" -lt "${_filled}" ]; then _out="${_out}="; else _out="${_out}-"; fi
        _i=$((_i + 1))
    done
    printf '[%s] %3d%%' "${_out}" "${_pct}"
}

# kib_to_human <KiB> — one-decimal GiB, falls back to MiB under 1GiB.
kib_to_human() {
    _kib="$1"
    if [ "${_kib}" -ge 1048576 ]; then
        _tenths=$((_kib * 10 / 1048576))
        printf '%d.%dG' "$((_tenths / 10))" "$((_tenths % 10))"
    else
        printf '%dM' "$((_kib / 1024))"
    fi
}

while true; do
    # shellcheck source=/dev/null
    [ -r "${env_file}" ] && . "${env_file}"

    _route="$(ip -4 route get 1.1.1.1 2> /dev/null | head -1)"
    _ip="$(echo "${_route}" | sed -n 's/.* src \([0-9.]*\).*/\1/p')"

    _k3s="$(systemctl is-active k3s.service 2> /dev/null || echo unknown)"
    _nodes="-"
    _ready="-"
    _pods="-"
    if [ "${_k3s}" = "active" ] && command -v kubectl > /dev/null 2>&1; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        _nodes="$(kubectl get nodes --no-headers 2> /dev/null | wc -l | tr -d ' ')"
        _ready="$(kubectl get node "${hostname}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null || echo unknown)"
        _pods="$(kubectl get pods -A --field-selector "spec.nodeName=${hostname}" --no-headers 2> /dev/null \
            | wc -l | tr -d ' ')"
    fi

    _up_s="$(cut -d' ' -f1 /proc/uptime 2> /dev/null)"
    _up_s="${_up_s%.*}"
    if [ -n "${_up_s:-}" ]; then
        _uptime="$((_up_s / 86400))d $(((_up_s % 86400) / 3600))h $(((_up_s % 3600) / 60))m"
    else
        _uptime="unknown"
    fi

    # CPU: two /proc/stat samples 0.3s apart, aggregate over all fields
    # after "cpu" (user nice system idle iowait irq softirq steal ...) so
    # kernels that add fields keep working without a parser change.
    _cpu_pct=0
    _c1="$(head -1 /proc/stat)"
    sleep 0.3
    _c2="$(head -1 /proc/stat)"
    _cpu_pct="$(
        # shellcheck disable=SC2086  # intentional word-splitting of the /proc/stat line
        set -- ${_c1}
        shift
        _idle1=$4
        _t1=0
        for _v in "$@"; do _t1=$((_t1 + _v)); done
        # shellcheck disable=SC2086  # intentional word-splitting of the /proc/stat line
        set -- ${_c2}
        shift
        _idle2=$4
        _t2=0
        for _v in "$@"; do _t2=$((_t2 + _v)); done
        _dt=$((_t2 - _t1))
        _di=$((_idle2 - _idle1))
        [ "${_dt}" -gt 0 ] && echo $(( (100 * (_dt - _di)) / _dt )) || echo 0
    )"
    _ncpu="$(nproc 2> /dev/null || grep -c ^processor /proc/cpuinfo)"

    _mem_total_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    _mem_avail_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    _mem_used_kib=$((_mem_total_kib - _mem_avail_kib))
    _mem_pct=$((_mem_used_kib * 100 / _mem_total_kib))

    # Disk: /usr/local (COS_PERSISTENT) is the real writable partition — k3s,
    # containerd, etcd, kubelet all bind-mount into it. The root filesystem
    # is a small read-only squashfs loop device and is not useful to show.
    _disk_line="$(df -Pk /usr/local 2> /dev/null | awk 'NR==2{print $2, $3, $5}')"
    _disk_total_kib="$(echo "${_disk_line}" | cut -d' ' -f1)"
    _disk_used_kib="$(echo "${_disk_line}" | cut -d' ' -f2)"
    _disk_pct="$(echo "${_disk_line}" | cut -d' ' -f3 | tr -d '%')"

    printf '\033[2J\033[H'
    echo "=============================================================="
    echo " ${hostname}  —  Kairos node"
    echo "=============================================================="
    echo " Cluster      : ${DNS:-?} (VIP ${VIP:-?})"
    echo " GitOps repo  : ${GITOPS_REPO:-?}"
    echo " GitOps path  : ${GITOPS_PATH:-?}"
    echo " IP address   : ${_ip:-none}"
    echo "--------------------------------------------------------------"
    printf ' %-13s: %s\n' "CPU (${_ncpu}c)" "$(bar "${_cpu_pct}")"
    printf ' Memory       : %s  %s / %s\n' "$(bar "${_mem_pct}")" "$(kib_to_human "${_mem_used_kib}")" "$(kib_to_human "${_mem_total_kib}")"
    printf ' Disk (data)  : %s  %s / %s\n' "$(bar "${_disk_pct:-0}")" "$(kib_to_human "${_disk_used_kib:-0}")" "$(kib_to_human "${_disk_total_kib:-0}")"
    echo "--------------------------------------------------------------"
    echo " k3s service  : ${_k3s}"
    echo " Node ready   : ${_ready}"
    echo " Pods running : ${_pods}"
    echo " Cluster nodes: ${_nodes}"
    echo " Uptime       : ${_uptime}"
    echo "=============================================================="
    echo " $(date '+%Y-%m-%d %H:%M:%S')  (read-only — no login on this system)"

    sleep 5
done
