# 0008 — Generic installer ISO with config self-dispatch

- Status: Accepted
- Date: 2026-07-19

## Context

Nodes install from a Kairos ISO. The repository holds per-node
configuration (ADR 0004), the node ID is derivable on the machine itself
(ADR 0007), and the repository is publicly readable. The installer must
end up with exactly the right fragments for the machine it runs on —
including the K3s cluster token, which is SOPS-encrypted in the repository
(ADR 0005).

## Problem

How does the installer know which node configuration to apply, and how does
it obtain the cluster token without the token ever being committed in
plaintext or baked into a widely shared image?

## Considered Alternatives

1. **One ISO per node (config baked in at build time)** — simple, but N
   ISOs to build, label, and rebuild on every config change; easy to boot
   the wrong one.
2. **Kairos `config_url`** — static per ISO; cannot select per node.
3. **Netboot with per-MAC config serving (AuroraBoot)** — attractive
   long-term, but requires a permanently running provisioning service and
   MAC-based matching; deferred.
4. **Generic ISO + self-dispatch** — the ISO carries only a bootstrap
   cloud-config and a dispatcher. At boot, the dispatcher derives the node
   ID (ADR 0007), fetches `nodes/<id>/fragments.list` from the repository,
   downloads the listed fragments into `/oem`, decrypts the K3s token, and
   lets the auto-installer proceed.

## Decision

Generic ISO with self-dispatch (option 4):

- `iso/bootstrap.yaml` — baked cloud-config; runs the dispatcher in the
  `network` stage, then auto-install proceeds.
- `iso/dispatch.sh` — POSIX-shell dispatcher; fails loudly and leaves the
  machine uninstalled if no `nodes/<id>/` exists.
- `nodes/<id>/fragments.list` — explicit, ordered fragment list per node.
  This also encodes the node's role (init vs. join) without dispatcher
  heuristics.
- Token path: the dispatcher fetches `secrets/k3s-token.sops.yaml`,
  decrypts it with a **dedicated cluster age key** shipped in the ISO
  overlay (never an engineer's personal key), and stages the token as
  `/oem/30-k3s-token.yaml`.
- `scripts/build-iso.sh` assembles the overlay (dispatcher, static sops
  binary — checksum-verified, cluster age key, config URL pinned to a
  branch) and builds via AuroraBoot in Docker. Pinned versions throughout.

## Consequences

- One ISO serves every node; adding a node requires no new image, only a
  repository directory.
- **The ISO is secret material**: it contains the cluster age private key.
  It must not be uploaded or shared; compromise of the ISO means rotating
  the cluster key (recipient removal + `sops updatekeys`) and the K3s token.
- Installation requires network access to raw.githubusercontent.com; an
  offline install needs the fragments placed in `/oem` manually (documented
  fallback, unchanged from ADR 0004).
- The config branch is fixed at build time (`dev-vm-cluster` for the dev
  cluster), keeping dev and future prod images cleanly separated.

## Rationale

Self-dispatch keeps machine identity, configuration selection, and secret
delivery in one auditable mechanism driven entirely by repository content.
It reuses the ADR 0007 identity rule instead of introducing a second
matching mechanism, and it degrades safely: unknown machines stay in the
live system instead of installing something wrong.
