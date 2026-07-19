# Architecture

## Purpose and Scope

This repository is the single source of truth for the configuration of all
Kairos nodes in the homelab. It covers OS-level provisioning (cloud-config),
node roles, installer image building, and the strategy for handling secrets
during bootstrap.

Workload deployment (manifests, Helm releases, GitOps) is out of scope and
will live in a separate repository once the cluster exists.

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

- control plane nodes only (currently planned: four); every node is a K3s
  server with embedded etcd and also runs workloads
- kube-vip in ARP mode provides the stable API endpoint `192.168.1.11`;
  node failure moves the VIP, kubeconfigs never reference a node IP
- heterogeneous hardware, currently a QEMU/UTM VM development cluster
  (branch `dev-vm-cluster`)
- cluster workloads managed via GitOps in a follow-up repository

Kairos nodes are provisioned with cloud-config files. Kairos reads all
cloud-config files available to the agent (e.g. from `/oem`) and merges them
in lexicographic filename order. This repository exploits that behaviour to
layer configuration instead of duplicating it.

## Repository Structure

```text
.
├── README.md
├── .sops.yaml              # SOPS creation rules (age recipients)
├── configs/
│   ├── base/
│   │   └── 00-base.yaml    # configuration shared by every node
│   └── roles/
│       ├── 10-server-init.yaml   # first server: --cluster-init (one per cluster)
│       ├── 10-server-join.yaml   # all other servers: join via VIP
│       └── 15-kube-vip.yaml      # control plane VIP (auto-deploy manifest)
├── nodes/                  # one directory per node (ADR 0007)
│   └── node-<id>/
│       ├── 20-node-<id>.yaml
│       └── fragments.list  # ordered fragment set, read by the dispatcher
├── templates/              # starting points for new node configurations
├── secrets/                # SOPS-encrypted material only (enforced by .gitignore)
├── iso/
│   ├── bootstrap.yaml      # cloud-config baked into the installer ISO
│   └── dispatch.sh         # node self-dispatch (ADR 0008)
├── scripts/
│   ├── bootstrap.sh        # idempotent repository skeleton generator
│   └── build-iso.sh        # builds the generic installer ISO (AuroraBoot)
└── docs/
    ├── architecture.md
    └── adr/                # architecture decision records
```

Rationale and considered alternatives: see
[ADR 0002](adr/0002-repository-layout.md).

## Configuration Strategy

Configuration is split into layers, combined per node via its
`fragments.list`:

| Layer | Location                          | Prefix | Content                                        |
|-------|-----------------------------------|--------|------------------------------------------------|
| Base  | `configs/base/00-base.yaml`       | `00-`  | users, SSH keys, install defaults, OS settings |
| Role  | `configs/roles/10-*.yaml`, `15-*` | `10-`/`15-` | K3s server settings, kube-vip              |
| Node  | `nodes/node-<id>/20-*.yaml`       | `20-`  | hostname, install device, network              |
| Token | staged by the dispatcher          | `30-`  | K3s cluster token (never committed)            |

The numeric prefixes define the merge order used by Kairos. Later fragments
override or extend earlier ones. There is deliberately no templating
engine; placeholders exist only in `templates/`.
Details: [ADR 0004](adr/0004-kairos-configuration-strategy.md).

## Node Identity

Node ID = `node-` + first segment of the SMBIOS product UUID, lowercase
(`/sys/class/dmi/id/product_uuid`). The ID names the node directory, its
fragment, and the hostname. See [ADR 0007](adr/0007-node-identity.md),
including the open point for Apple Silicon hardware.

## Provisioning Workflow

One generic installer ISO serves all nodes ([ADR 0008](adr/0008-installer-config-dispatch.md)):

1. `scripts/build-iso.sh` builds the ISO: Kairos base image + baked
   bootstrap config + overlay (dispatcher, static sops binary, dedicated
   cluster age key, config URL pinned to a branch). The ISO embeds a
   private key and is therefore secret material.
2. The machine boots the ISO; the dispatcher derives the node ID, fetches
   the fragments named in `nodes/<id>/fragments.list` into `/oem`, decrypts
   the K3s token, and stages it as `30-k3s-token.yaml`.
3. The Kairos auto-installer applies the staged configuration and powers
   the machine off. On headless hosts the powered-down state is the
   "installation finished" signal: remove the boot medium, power on, the
   node starts (or joins) the cluster.
4. Machines without a `nodes/<id>/` directory poll the repository and
   install nothing until their directory appears — nothing installs by
   accident.

Bootstrap order for a new cluster: the `10-server-init` node first; once
the VIP answers, the remaining nodes in any order.

## Secret Management

Secrets are never committed in plaintext (ADR 0005):

1. **Bootstrap secrets** — SOPS-encrypted YAML in `secrets/` (age).
   Recipients: engineer keys plus a dedicated cluster key that ships only
   inside the installer ISO. `.gitignore` blocks everything in `secrets/`
   except `*.sops.yaml` and documentation.
2. **Runtime secrets** — planned via HashiCorp Vault or an
   external-secrets operator once the cluster runs; nothing in the current
   layout blocks that integration.

## Future Extensions

- CI validation: YAML lint, cloud-config schema checks, placeholder checks
- Netboot provisioning (AuroraBoot) replacing per-machine ISO boots
- HashiCorp Vault for runtime secrets; SOPS remains for bootstrap secrets
- GitOps repository (Flux or Argo CD) for cluster workloads
- LoadBalancer services via kube-vip (`svc_enable`), separate ADR
- Node identity fallback for Apple Silicon (device-tree serial), extends
  ADR 0007
