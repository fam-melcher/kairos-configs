# 0013 — Single-source cluster values

- Status: Accepted
- Date: 2026-07-22

## Context

After ADR 0012 each cluster's VIP appeared in three value-carrying files
(`12-cluster.yaml` tls-san, `13-join.yaml` server URL, `15-kube-vip.yaml`
manifest), the DNS name in two. Changing a value meant finding every copy;
nothing enforced their consistency.

## Problem

How can each cluster value exist exactly once in the repository while
every consumer still receives it, without introducing a repository
templating engine (ADR 0004 deliberately has none)?

## Considered Alternatives

1. **Consistency check only** — keep the copies, let CI verify they
   match. Prevents drift but not the duplication itself.
2. **Repository-side generation** — render the fragments from a values
   file at commit time. The generated copies still live in git (the grep
   still hits them), and it *is* a templating engine.
3. **Runtime rendering on the node** — one values fragment per cluster
   ships `VIP` and `CLUSTER_DNS` to `/etc/kairos-cluster/cluster.env`;
   all consumers render their files from it at boot. Values exist once in
   the repo; the repo itself stays literal.

## Decision

Option 3.

- `clusters/<name>/config/11-cluster.yaml` is the **single place** a
  cluster's values are defined — and it is **pure data**, no stages, no
  rendering:

  ```yaml
  values:
    vip: "192.168.30.2"
    dns: "k8s-prod.home.fam-melcher.net"
  ```

- The magic lives elsewhere. `11-cluster.yaml` is real YAML, so it is read
  with a real YAML tool — **yq** (mikefarah/yq), bundled in the ISO
  overlay next to sops (same checksum-verified download pattern in
  `build-iso.sh`; hadron ships neither). The dispatcher runs one yq
  expression converting every scalar entry under `values:` generically to
  `KEY=VALUE` (dash → underscore, uppercased) and stages a *generated*
  cloud-config fragment shipping them to the installed system as
  `/etc/kairos-cluster/cluster.env` — the same pattern as the generated
  token fragment (ADR 0008). Future scalar values need no dispatcher
  change; lists and nested maps are skipped by the yq filter until a
  consumer needs one. `scripts/validate-nodes.sh` reads the same file with
  plain `yq eval '.values.vip'` queries — no fragment anywhere is read
  with sed/awk text-matching once it is real YAML.
- Consumers are value-free and therefore cluster-neutral, shared in
  `configs/cluster/`, all rendering at boot stage from `cluster.env`:
  - `12-tls-san.yaml` renders the tls-san drop-in (`${VIP}`, `${DNS}`);
  - `13-join.yaml` (BOOTSTRAP-ROLE, installer-selected) renders the join
    target;
  - `15-kube-vip.yaml` stages the manifest with an `@VIP@` token and
    renders it.
  Boot runs strictly after initramfs (where the generated values fragment
  writes `cluster.env`), so the values provably exist; all renders are
  idempotent on every boot.
- The prod-only MTU settings left `12-cluster.yaml` (now gone) for their
  own fragment `clusters/k8s-prod/config/14-net-mtu.yaml`.
- `fragments.list` is **composed, not templated**: `add-node.sh` builds it
  from `00-base` + all non-BOOTSTRAP fragments in the cluster's config
  dir and `configs/cluster/`, sorted by numeric prefix, + the node
  fragment. `templates/fragments.list.tmpl` is gone; new cluster
  fragments join future node lists automatically.
- The dispatcher's discovery (ADR 0011) captures `vip`/`dns` directly via
  yq while converting the values file — no second read of the generated
  fragment; the validator additionally requires every node list to
  contain its cluster's values fragment.
- This is not a repository templating engine: the repo stays literal, and
  rendering happens on the node from values the node was shipped —
  ADR 0004's decision stands. Amends ADR 0012 (the per-cluster config dir
  now holds the values fragment plus genuinely cluster-specific extras).

## Consequences

- `grep -r <VIP>` finds exactly one hit (plus immutable ADR history);
  changing a VIP or DNS name is a one-line edit.
- Consumers of the values are shared files — a fix lands once for all
  clusters.
- Runtime indirection: what k3s and kube-vip actually see exists only on
  the node (`/etc/rancher/k3s/config.yaml.d/`, rendered manifest), not in
  the repo. Debugging reads the rendered files on the node.
- Installed nodes are unaffected until reinstall: paths and rendered
  contents are identical to the previous static files.

- One more bundled binary in the ISO overlay (yq, checksum-verified like
  sops) and a new engineer-machine dependency for `validate-nodes.sh`.

## Rationale

Values once, consumers shared, rendering where the values are needed —
the smallest arrangement in which nothing can drift, bought with runtime
indirection instead of a repo templating engine that ADR 0004 rejects.
Reading real YAML with a real YAML tool instead of sed/awk regexes is the
same principle applied to the tooling: text-pattern matching against a
structured format is fragile in exactly the way `values:` is meant to
prevent.
