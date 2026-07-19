# 0006 — HA control plane topology with kube-vip

- Status: Accepted
- Date: 2026-07-19

## Context

The cluster shall consist of control plane nodes only (currently planned:
four). K3s servers are schedulable by default, so every node carries both
the control plane and workloads. The Kubernetes API must stay reachable
under one stable address when individual nodes fail.

## Problem

How are the all-server topology and a highly available API endpoint
implemented?

## Considered Alternatives

1. **Dedicated workers + separate control plane** — classic split; rejected
   by requirement (all nodes shall be control planes).
2. **DNS round-robin / client-side failover** — no health awareness, stale
   entries during outages, kubeconfig juggling.
3. **External load balancer (haproxy/keepalived on separate hardware)** —
   another machine to operate; single point of failure unless doubled.
4. **kube-vip in ARP mode on the control planes themselves** — floating VIP
   via leader election (Kubernetes lease), gratuitous ARP on failover, no
   extra hardware.
5. **Kairos p2p mode with native `kubevip:` block** — provider-kairos
   deploys kube-vip automatically, but only in the p2p coordination path
   (`internal/role/p2p/master.go`; verified in source — the non-p2p
   `oneTimeBootstrap` path never deploys kube-vip). Requires EdgeVPN
   coordination, a `network_token` secret, and dynamic role assignment —
   conflicting with the explicit per-node role assignment of ADR 0004.

## Decision

- All nodes are K3s servers with embedded etcd. One node per cluster uses
  `configs/roles/10-server-init.yaml` (`--cluster-init`); all others use
  `10-server-join.yaml`, joining through the VIP.
- kube-vip (option 4) runs in ARP mode as a DaemonSet on all control plane
  nodes, deployed through the K3s auto-deploy manifest directory
  (`configs/roles/15-kube-vip.yaml`).
- VIP: `192.168.1.11`, outside the DHCP pool. Set as `--tls-san` on every
  server so the API certificate covers it.
- kube-vip handles the control plane VIP only (`svc_enable: false`);
  LoadBalancer services are a separate, later decision.

## Consequences

- Losing the VIP-holding node moves the VIP to another server within
  seconds; joins and kubeconfigs never reference a node IP.
- ARP mode requires all nodes in the same L2 segment.
- **Even node count caveat**: four etcd members tolerate exactly one
  failure — the same as three. A fifth node (or accepting the limit) is a
  conscious follow-up decision.
- kube-vip version is pinned in the manifest and must be bumped
  deliberately.

## Rationale

kube-vip is the standard answer for a self-contained HA control plane
without extra hardware. The manifest-based deployment matches kube-vip's
official K3s documentation, keeps role assignment explicit, and avoids
adopting the p2p stack solely for its side effect of installing kube-vip.
