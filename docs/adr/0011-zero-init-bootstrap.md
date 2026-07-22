# 0011 — Zero-init bootstrap: installer-time role discovery

- Status: Accepted
- Date: 2026-07-22

## Context

Until now the repository encoded cluster genesis as node state: exactly one
node's `fragments.list` referenced `configs/roles/10-server-init.yaml`
(`--cluster-init`), all others the join role. That entry outlives its
purpose — it describes a one-time installer action, not a property of the
node. A reinstall of the former init node would re-run `--cluster-init` and
create a second cluster next to the running one; avoiding that required
editing the repository and remembering which machine bootstrapped the
cluster. Both violate the reproducibility goal ("any node can be
reinstalled from this repository alone").

## Problem

How does an installing node decide whether to join the existing cluster or
initialise a new one, without that decision being permanently encoded in
node state?

## Considered Alternatives

1. **Status quo** — init role in one node's `fragments.list`; the footgun
   described above.
2. **Human-triggered bootstrap channel** (dedicated bootstrap ISO, marker
   USB, sops-encrypted grant) — race-free, but requires human intervention
   for genesis; rejected by requirement (fully autonomous).
3. **Boot-time discovery with identity responders on every node** —
   long-running discovery services, subnet sweeps, deterministic candidate
   election. Strongest guarantees, but adds a permanent service and a
   protocol for a rare event; rejected as over-engineered for this
   environment (v0.9 scope).
4. **Installer-time discovery against the live cluster** — the dispatcher
   probes the API through the VIP and inspects the presented certificate;
   the running cluster is authoritative for its own existence. No new
   services, no new protocols, decision made exactly once per install.

## Decision

Option 4. The repository invariant:

> Node definitions describe permanent node configuration only. Bootstrap
> role selection is an installer-time decision and must never be encoded
> in node state.

- `nodes/*/fragments.list` carries only permanent fragments (base,
  environment, node). The bootstrap fragments
  (`configs/roles/10-server-init.yaml`, `10-server-join.yaml`,
  `configs/env/13-join.yaml`) remain in the repository as installer
  actions, are marked with a `BOOTSTRAP-ROLE` header comment, and are
  resolved exclusively by `iso/dispatch.sh` after discovery.
- Discovery (in `iso/dispatch.sh`, after fragment staging): probe
  `https://<VIP>:6443`, up to 6 attempts 5 s apart (tolerates kube-vip
  failover, which completes in seconds). Probe parameters are parsed from
  the fetched fragments — the VIP from the join target in `13-join.yaml`,
  the expected DNS name from the `tls-san` list in `12-cluster.yaml` — so
  no value exists twice.
- Three outcomes:
  - **Answer, certificate contains the VIP as IP SAN and the cluster DNS
    name (`k8s-prod.home.fam-melcher.net`) as DNS SAN** → join: stage
    `10-server-join.yaml` + `13-join.yaml`.
  - **No answer after all attempts** → genesis: stage
    `10-server-init.yaml`.
  - **Answer with unexpected SANs** → fatal abort; the machine stays in
    the live system. Something else owns the VIP, and treating it as "no
    cluster" would initialise a twin next to a live system.
- The certificate is read without chain validation (`curl -k` +
  `openssl x509`): the cluster CA is self-signed and rotatable by design,
  so identity is asserted through the SAN values, which come from this
  repository's configuration. Authentication remains entirely k3s's job
  (cluster token, ADR 0008); discovery answers existence, not trust.
- The per-environment DNS SAN is the identity mark; environments must use
  distinct names so an installer for one environment never joins another.
- The installed system never re-runs discovery; it boots with the role
  selected at install time. Existing members restart from their etcd state
  and are unaffected.
- Regression guard: `scripts/validate-nodes.sh` (run by CI) fails when any
  `fragments.list` references a missing file, a `BOOTSTRAP-ROLE`-marked
  fragment, or a known bootstrap fragment name.

## Consequences

- Any node — including the one that once initialised the cluster — is
  reinstallable without repository edits; an existing cluster is always
  preferred over creating a new one.
- Adding a node no longer involves a role choice (`add-node.sh <id>
  [device]`).
- One-time migration: the live nodes' serving certificate must present the
  new DNS SAN before any new installer probes it (`tls-san` addition +
  rolling k3s restart); k3s does not add unlisted SANs to the certificate.
- Accepted residual risks (v0.9, deliberate):
  - Two fresh machines installed simultaneously onto an empty network can
    both self-designate genesis. Installs are deliberate operator acts in
    this environment (a node installs only after its directory is pushed),
    so simultaneity is operator-avoidable.
  - Installing a fresh node while the entire cluster is unreachable
    (powered off, partitioned) yields a false genesis. The ~30 s probe
    window is a liveness check, not proof of absence. Distinguishing "no
    cluster" from "cluster invisible" is not solvable by probing; solving
    it needs a coordination mechanism (alternatives 2/3) and is out of
    scope here.

## Rationale

The running cluster is the only authority on its own existence; asking it
directly is simpler and more truthful than encoding history in the
repository. Delegating the check to the API certificate reuses material
k3s maintains anyway, keeps authentication where it already lives, and
needs no new services or protocols — the smallest change that removes the
standing reinstall footgun.
