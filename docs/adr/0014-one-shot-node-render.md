# 0014 — One-shot render of node-local cluster state

- Status: Accepted
- Date: 2026-07-23

## Context

[ADR 0013](0013-single-source-cluster-values.md) renders `cluster.env`,
the tls-san drop-in, the join target, and the kube-vip manifest at boot
from the node's `/etc/kairos-cluster/cluster.env`, "idempotently on every
boot" — by design, for the life of the node, since the driving fragments
stay in `/oem` and Kairos re-runs every stage it finds there on every
boot.

This repository's job is installing and initially configuring a node,
then handing off to other mechanics for administration (day-2 operations
are out of scope here). Re-rendering forever defeats that handoff: once a
node is up, the rendered artifacts (`config.yaml.d/10-env.yaml`,
`config.yaml.d/20-join.yaml`, the kube-vip manifest applied through K3s's
auto-deploy directory) become things a live cluster's own tooling should
be free to change — for example an operator moving the VIP to a new
subnet. Any such change is silently reverted on the next reboot, because
the boot stage re-derives the same file from the node's original,
install-time `cluster.env`, which nothing updates thereafter.

## Problem

How can each fragment render its value exactly once — early enough to
seed a working node — without continuing to overwrite whatever the live
cluster does with that value afterwards?

## Considered Alternatives

1. **Status quo** — render every boot. Simple, but permanently blocks any
   in-cluster VIP administration; the footgun this ADR exists to remove.
2. **Guard file / marker check** — each script tests for a sentinel
   (`test -f /etc/kairos-cluster/.rendered-12` `|| { render; touch ...;
   }`) before rendering. Works, but adds a second moving part (the
   marker) per fragment and two ways to reset it back to "unrendered"
   inconsistently between fragments.
3. **Delete the fragment's own `/oem` file after it runs** — Kairos only
   executes stages it finds in `/oem` at boot; a fragment that removes
   itself as its last command simply is not there to run again next
   boot. No new state to track — the fragment's own presence/absence in
   `/oem` *is* the marker, already the mechanism ADR 0013 uses to decide
   which role fragments (`10-server-init.yaml` vs. `10-server-join.yaml`)
   apply to a node.

## Decision

Option 3. Every render-from-`cluster.env` fragment deletes its own
`/oem/*.yaml` file as the last thing it does, so it runs on exactly one
boot — the node's first — never again:

- `clusters/<name>/config/11-cluster.yaml` → generated `/oem/11-cluster.yaml`
  (`iso/dispatch.sh`'s `stage_cluster_values`): a second `initramfs` stage
  step removes it right after `cluster.env` is written.
- `configs/cluster/12-tls-san.yaml`: every server node needs its own
  first-boot render — each generates its own dynamic serving cert locally,
  so this is scoped to "this node's first boot", not "the cluster's first
  boot" or "the init node only". Deletes `/oem/12-tls-san.yaml` after
  writing `config.yaml.d/10-env.yaml`.
- `configs/cluster/13-join.yaml` (BOOTSTRAP-ROLE, join nodes only): same
  per-node-first-boot scope. Deletes `/oem/13-join.yaml` after writing
  `config.yaml.d/20-join.yaml`.
- `configs/cluster/15-kube-vip.yaml`: staging the manifest once is
  sufficient — K3s's auto-deploy controller applies it as a normal,
  cluster-wide k8s resource once any server has applied it, so every
  node in `fragments.list` redundantly doing so on its own first boot is
  harmless (same content, idempotent apply). What must stop is
  reapplying from disk on *every later* boot, which would revert a live
  edit to the DaemonSet. Deletes `/oem/15-kube-vip.yaml` after rendering
  the manifest into the K3s manifests directory.

The rendered artifacts on disk (`config.yaml.d/*.yaml`, the applied
kube-vip DaemonSet) are untouched by this change and keep being read by
K3s / K8s on every start, same as before — only the boot-stage
*re-derivation from `cluster.env`* stops after the first boot.

## Consequences

- A live cluster's VIP, DNS SAN, or join target can be changed by
  whatever day-2 tooling the operator sets up, and it sticks across
  reboots — the gap this ADR closes.
- `cluster.env` itself is now truly install-time-only, matching its
  existing "do not edit on the node" comment: nothing rewrites it after
  the node's first boot, so it is a frozen snapshot of the values used at
  install, not a live source of truth to introspect for the node's
  *current* configuration.
- A node that is reinstalled goes through dispatch again and gets a fresh
  `/oem`, so the one-shot fragments render again exactly once, as
  expected.
- No new marker files or state to keep in sync; a fragment's own
  presence in `/oem` remains the only signal Kairos needs.

## Rationale

The repository's own boot mechanism already treats "is this fragment
still in `/oem`" as the authority on whether to run it (ADR 0011's role
fragments rely on exactly this). Reusing it here — self-deleting after
one render — needs no new concept, only a stop condition on stages that
were unconditionally recurring for no reason once the node they seed is
up.
