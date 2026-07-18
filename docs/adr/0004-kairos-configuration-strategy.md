# 0004 — Kairos configuration strategy

- Status: Accepted
- Date: 2026-07-18

## Context

Kairos provisions nodes from cloud-config YAML. The agent reads all
cloud-config files available to it (for example every YAML in `/oem`) and
merges them in lexicographic filename order — later files override or extend
earlier ones. The homelab will contain several nodes that share most
configuration and differ only in role and machine-specific values.

## Problem

How is a node's configuration composed so that shared settings exist once,
role settings exist once per role, and only genuinely node-specific values
live per node?

## Considered Alternatives

1. **Single cloud-config per node** — rejected in ADR 0002 (duplication,
   drift).
2. **Build-time rendering with a templating engine** — rejected for now in
   ADR 0002 (toolchain cost, harder debugging).
3. **Three-layer fragment model using Kairos' merge order** — base, role,
   and node fragments with numeric filename prefixes that encode precedence.

## Decision

Three-layer fragment model (option 3):

| Layer | File                              | Prefix | Typical content                                  |
|-------|-----------------------------------|--------|--------------------------------------------------|
| Base  | `configs/base/00-base.yaml`       | `00-`  | users, SSH keys, install defaults, OS hardening  |
| Role  | `configs/roles/10-<role>.yaml`    | `10-`  | `k3s:` (server) or `k3s-agent:` (agent) settings |
| Node  | `nodes/<host>/20-<host>.yaml`     | `20-`  | hostname, network, storage device                |

Conventions:

- Every fragment is a complete, valid cloud-config file starting with
  `#cloud-config`.
- Prefixes are mandatory: `00-` base, `10-` role, `20-` node. Gaps are
  reserved for future layers (e.g. `15-` site/network segment).
- Node directories are named exactly like the node's hostname.
- Deployment of a node means providing exactly its three fragments to the
  installer (custom ISO `/oem`, config partition, or `kairos-agent
  manual-install` after concatenation by a future render script).
- New node fragments start from `templates/20-node.yaml.tmpl`; placeholders
  use `@VARIABLE@` markers so unreplaced placeholders fail loudly instead of
  producing a half-valid config.

## Consequences

- Adding a node = one new directory with one small file.
- Adding a role = one new file under `configs/roles/`.
- The effective configuration of a node is reproducible from the repository
  by listing its three fragments; no hidden state.
- A render/validation script (planned) can later assemble and lint the
  fragment set per node without changing this structure.

## Rationale

The model uses a documented Kairos mechanism instead of external tooling,
keeps every layer independently reviewable, and encodes precedence in the
filenames where every engineer can see it.
