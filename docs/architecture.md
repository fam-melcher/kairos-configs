# Architecture

## Purpose and Scope

This repository is the single source of truth for the configuration of all
Kairos nodes in the homelab. It covers OS-level provisioning (cloud-config),
node roles, installer image building, and the strategy for handling secrets
during bootstrap.

Workload deployment (manifests, Helm releases, GitOps) is out of scope
and lives in a separate repository (`kairos-gitops`) once the cluster
exists. This repository's involvement stops at provisioning the GitOps
controller itself (ADR 0015) — installing ArgoCD is provisioning, same
category as installing k3s; what ArgoCD deploys is not.

## Goals

Ordered by priority:

1. Security — no plaintext secrets in the repository, minimal attack surface
2. Reproducibility — any node can be reinstalled from this repository alone
3. Maintainability — small, composable configuration fragments
4. Understandability — explicit structure, documented decisions
5. Extensibility — new nodes, roles, and environments without restructuring
6. Automation — no manual steps that a script can perform

## Target Architecture

The homelab runs a K3s cluster on Kairos, an immutable, container-based
Linux OS. The target state (ADR 0006):

- control plane nodes only (currently planned: four per cluster); every
  node is a K3s server with embedded etcd and also runs workloads
- kube-vip in ARP mode provides each cluster's stable API endpoint (VIP in
  `clusters/<name>/config/11-cluster.yaml`); node failure moves the VIP,
  kubeconfigs never reference a node IP
- two clusters (ADR 0012): `k8s-prod` on physical hardware, `k8s-dev` on
  Hyper-V VMs for testing changes before promotion
- cluster workloads managed via GitOps (`kairos-gitops`, public),
  bootstrapped automatically on the genesis node (ADR 0015)

Kairos nodes are provisioned with cloud-config files. Kairos reads all
cloud-config files available to the agent (e.g. from `/oem`) and merges them
in lexicographic filename order. This repository exploits that behaviour to
layer configuration instead of duplicating it.

## Repository Structure

```text
.
├── README.md
├── .sops.yaml              # SOPS creation rules, one per cluster path (ADR 0012)
├── configs/
│   ├── base/
│   │   └── 00-base.yaml    # configuration shared by every node
│   ├── cluster/            # value-free consumers, shared by all clusters (ADR 0013)
│   │   ├── 12-tls-san.yaml       # tls-san renderer
│   │   ├── 13-join.yaml          # join target renderer; installer-selected (ADR 0011)
│   │   └── 15-kube-vip.yaml      # kube-vip manifest renderer
│   └── roles/              # cluster-neutral role fragments
│       ├── 10-server-init.yaml   # --cluster-init; installer-selected (ADR 0011)
│       ├── 10-server-join.yaml   # joining server; installer-selected (ADR 0011)
│       └── 16-argocd.yaml        # ArgoCD bootstrap; genesis-only, installer-selected (ADR 0015)
├── clusters/               # one directory per cluster (ADR 0012);
│   └── <name>/             # name = first segment of the cluster DNS name
│       ├── config/
│       │   ├── 11-cluster.yaml   # THE cluster values (pure data, ADR 0013)
│       │   └── …                 # genuinely cluster-specific extras (e.g. 14-net-mtu)
│       ├── nodes/
│       │   └── node-<id>/
│       │       ├── 20-node-<id>.yaml
│       │       └── fragments.list  # ordered fragment set, read by the dispatcher
│       └── secrets/        # SOPS-encrypted material only (enforced by .gitignore)
├── templates/              # starting points for new node and cluster configurations
│   └── cluster/            # rendered by scripts/add-cluster.sh
├── iso/
│   ├── bootstrap.yaml      # cloud-config baked into the installer ISO
│   └── dispatch.sh         # node self-dispatch (ADR 0008)
├── scripts/
│   ├── add-cluster.sh      # scaffold a new cluster (dirs, config, key, sops, token)
│   ├── add-node.sh         # scaffold a node inside a cluster
│   ├── bootstrap.sh        # idempotent repository skeleton generator
│   ├── build-iso.sh        # builds the installer ISO for one branch × cluster
│   └── validate-nodes.sh   # repository invariants (CI)
└── docs/
    ├── architecture.md
    └── adr/                # architecture decision records
```

Rationale and considered alternatives: see
[ADR 0002](adr/0002-repository-layout.md) and
[ADR 0012](adr/0012-cluster-directories-branch-stages.md).

## Branches and Environments

Branches are stages, directories are environments (ADR 0012): `main` is
what production machines poll, `dev` is the staging branch. A change flows
feature branch → PR → `dev` → tested on the dev cluster → PR → `main`.
Both branches carry all `clusters/<name>/` directories; a change to a
cluster's directory only reaches its machines when it lands on the branch
their ISO polls.

## Configuration Strategy

Configuration is split into layers. Permanent layers are combined per node
via its `fragments.list`; the bootstrap role is selected by the installer
at install time (ADR 0011) and the token is staged by the dispatcher:

| Layer | Location                          | Prefix | Selected by | Content                                        |
|-------|-----------------------------------|--------|-------------|------------------------------------------------|
| Base    | `configs/base/00-base.yaml`             | `00-`  | fragments.list | users, SSH keys, install defaults, OS settings |
| Role    | `configs/roles/10-*.yaml`               | `10-`  | installer (ADR 0011) | K3s bootstrap role (init/join), cluster-neutral |
| Values  | `clusters/<name>/config/11-cluster.yaml` | `11-` | fragments.list | THE cluster values: VIP + DNS name (ADR 0013) |
| Cluster | `clusters/<name>/config/1[2-9]-*.yaml` + `configs/cluster/1[2-9]-*.yaml` | `12-`–`19-` | fragments.list, except `13-join.yaml` (installer) | cluster extras + shared value-free renderers (join target, kube-vip) |
| GitOps bootstrap | `configs/roles/16-argocd.yaml` | `16-` | installer, genesis-only (ADR 0015, ADR 0017) | ArgoCD install manifest (kubectl apply, one-shot) + root Application, value-free |
| Node    | `clusters/<name>/nodes/node-<id>/20-*.yaml` | `20-` | fragments.list | hostname, install device, network              |
| Token   | staged by the dispatcher                | `30-`  | dispatcher  | K3s cluster token (never committed)            |

The numeric prefixes define the merge order used by Kairos. Later fragments
override or extend earlier ones. There is deliberately no templating
engine; placeholders exist only in `templates/`.
Details: [ADR 0004](adr/0004-kairos-configuration-strategy.md).

Repository invariant (enforced by `scripts/validate-nodes.sh` in CI):

> Node definitions describe permanent node configuration only. Bootstrap
> role selection is an installer-time decision and must never be encoded
> in node state.

## Node Identity

Node ID = `node-` + first 8 hex of SHA-256 over the lowercased SMBIOS
product UUID (`/sys/class/dmi/id/product_uuid`). The ID names the node
directory, its fragment, and the hostname. See
[ADR 0010](adr/0010-node-identity-hash.md) (and the superseded
[ADR 0007](adr/0007-node-identity.md), including the open point for Apple
Silicon hardware).

## Provisioning Workflow

One generic installer ISO serves all nodes ([ADR 0008](adr/0008-installer-config-dispatch.md)):

1. `scripts/build-iso.sh <branch> [cluster]` builds the ISO: Kairos base
   image + baked bootstrap config + overlay (dispatcher, static sops
   binary, the cluster's age key, config URL pinned to a branch, cluster
   name). The ISO embeds a private key and is therefore secret material.
2. The machine boots the ISO; the dispatcher derives the node ID, fetches
   the fragments named in `clusters/<cluster>/nodes/<id>/fragments.list`
   into `/oem`, probes for the existing cluster and stages the join or
   init role accordingly (ADR 0011), then decrypts the K3s token and
   stages it as `30-k3s-token.yaml`.
3. The Kairos auto-installer applies the staged configuration and powers
   the machine off. On headless hosts the powered-down state is the
   "installation finished" signal: remove the boot medium, power on, the
   node starts (or joins) the cluster.
4. Machines without a node directory in their ISO's cluster poll the
   repository and install nothing until the directory appears — nothing
   installs by accident.

Bootstrap order for a new cluster: none — nodes install in any order. The
first installer that finds no cluster on the VIP initialises it; every
later installer finds the cluster (API certificate SAN check) and joins
(ADR 0011). Avoid starting several installs simultaneously onto an empty
network; that is the one race the v0.9 discovery does not arbitrate.

## Secret Management

Secrets are never committed in plaintext (ADR 0005):

1. **Bootstrap secrets** — SOPS-encrypted YAML in
   `clusters/<name>/secrets/` (age), one recipient rule per cluster path
   (ADR 0012). Recipients: engineer keys plus the cluster's dedicated key
   that ships only inside that cluster's installer ISO. `.gitignore`
   blocks everything in the secrets directories except `*.sops.yaml` and
   documentation.
2. **Runtime secrets** — planned via HashiCorp Vault or an
   external-secrets operator once the cluster runs; nothing in the current
   layout blocks that integration.

## Future Extensions

- CI validation beyond the existing invariant/shellcheck workflow: YAML
  lint, cloud-config schema checks, placeholder checks
- Netboot provisioning (AuroraBoot) replacing per-machine ISO boots
- HashiCorp Vault for runtime secrets; SOPS remains for bootstrap secrets
- `kairos-gitops` content itself (AppProjects, further Applications,
  ingress, Vault, CI runner) — this repo's job stops at ArgoCD existing
  and pointed at the right path (ADR 0015)
- LoadBalancer services via kube-vip (`svc_enable`), separate ADR
- Node identity fallback for Apple Silicon (device-tree serial), extends
  ADR 0007
