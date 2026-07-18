# Architecture

## Purpose and Scope

This repository is the single source of truth for the configuration of all
Kairos nodes in the homelab. It covers OS-level provisioning (cloud-config),
node roles, and the strategy for handling secrets during bootstrap.

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
Linux OS. The target state:

- multiple control plane nodes (HA-capable, starting with one)
- multiple worker nodes on heterogeneous hardware
- nodes possibly located in different network segments
- cluster workloads managed via GitOps in a follow-up repository

Kairos nodes are provisioned with cloud-config files. Kairos reads all
cloud-config files available to the agent (e.g. from `/oem`) and merges them
in lexicographic filename order. This repository exploits that behaviour to
layer configuration instead of duplicating it.

## Repository Structure

```text
.
├── README.md
├── .sops.yaml              # SOPS configuration (encryption rules)
├── configs/
│   ├── base/               # configuration shared by every node
│   │   └── 00-base.yaml
│   └── roles/              # role-specific configuration
│       ├── 10-control-plane.yaml
│       └── 10-worker.yaml
├── nodes/                  # one directory per physical/virtual node
│   └── <hostname>/
│       └── 20-<hostname>.yaml
├── templates/              # starting points for new node configurations
│   └── 20-node.yaml.tmpl
├── secrets/                # SOPS-encrypted material only (enforced by .gitignore)
├── scripts/
│   └── bootstrap.sh        # idempotent repository skeleton generator
└── docs/
    ├── architecture.md
    └── adr/                # architecture decision records
```

Rationale and considered alternatives: see
[ADR 0002](adr/0002-repository-layout.md).

## Configuration Strategy

Configuration is split into three layers, combined per node:

| Layer | Location                        | Prefix | Content                                        |
|-------|---------------------------------|--------|------------------------------------------------|
| Base  | `configs/base/00-base.yaml`     | `00-`  | users, SSH keys, install defaults, OS settings |
| Role  | `configs/roles/10-<role>.yaml`  | `10-`  | K3s server/agent settings per role             |
| Node  | `nodes/<host>/20-<host>.yaml`   | `20-`  | hostname, network, device-specific settings    |

The numeric prefixes define the merge order used by Kairos. Later fragments
override or extend earlier ones. A node is provisioned by placing exactly
three files on the installation medium (or in `/oem`): its base, role, and
node fragment.

There is deliberately no templating engine. Fragments are plain
cloud-config; placeholders exist only in `templates/` as starting points for
new node files. Details: [ADR 0004](adr/0004-kairos-configuration-strategy.md).

## Secret Management

Secrets are never committed in plaintext. The strategy has two stages:

1. **Bootstrap secrets** (needed before a cluster exists — K3s cluster
   token, user password hashes, Wi-Fi credentials): stored in `secrets/` as
   SOPS-encrypted YAML using age keys. `.gitignore` blocks everything in
   `secrets/` except `*.sops.yaml` files and documentation.
2. **Runtime secrets** (needed by workloads at runtime): out of scope here;
   planned via HashiCorp Vault or an external-secrets operator once the
   cluster runs. This repository only guarantees that nothing in its layout
   blocks that integration.

Key handling, rotation, and access control: see
[ADR 0005](adr/0005-secret-management.md).

## Provisioning Workflow

Current (manual, documented; automation is a planned extension):

1. Decrypt required bootstrap secrets locally (`sops -d`).
2. Collect the three fragments for the target node.
3. Provide them to the Kairos installer (custom ISO `/oem`, USB config
   partition, or `kairos-agent manual-install`).
4. Node installs, reboots, and joins the cluster according to its role.

## Future Extensions

- CI validation: YAML lint and cloud-config schema checks on pull requests
- A render script that assembles and validates per-node configuration sets
- Automated image/ISO building (e.g. AuroraBoot) with embedded fragments
- HashiCorp Vault for runtime secrets, SOPS remains for bootstrap secrets
- GitOps repository (Flux or Argo CD) for cluster workloads
