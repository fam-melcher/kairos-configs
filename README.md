# kairos-configs

Declarative Kairos node configuration for the homelab.

This repository is the single source of truth for provisioning all Kairos
nodes: shared base configuration, server role definitions and per-node
overrides. Any node can be reinstalled from this repository plus one
private age key.

## Layout

```text
configs/base/      cloud-config shared by every node (00- prefix)
configs/roles/     server role fragments, kube-vip (10-/15- prefix)
nodes/<node-id>/   node fragment + fragments.list (20- prefix, ADR 0007)
templates/         starting points for new node fragments
secrets/           SOPS-encrypted material only (enforced by .gitignore)
iso/               installer ISO bootstrap config + dispatcher (ADR 0008)
scripts/           repository tooling (bootstrap.sh, build-iso.sh)
docs/              architecture overview and decision records
```

A node's configuration is the ordered set of its three fragments
(base, role, node); Kairos merges them by filename order. Details:
[docs/architecture.md](docs/architecture.md).

## Usage

Recreate or repair the repository skeleton (idempotent, never overwrites):

```sh
scripts/bootstrap.sh
```

Add a node: see [nodes/README.md](nodes/README.md).

Build the installer ISO (embeds the cluster age key — treat the image as
secret material):

```sh
scripts/build-iso.sh [branch]
```

## Secrets

No plaintext secrets, ever. Bootstrap secrets are SOPS/age-encrypted under
`secrets/`; runtime secrets move to Vault once the cluster runs. See
[ADR 0005](docs/adr/0005-secret-management.md).

## Contributing

- No direct commits to `main`; every change via feature branch and pull request.
- No force pushes, no history rewriting.
- [Conventional Commits](https://www.conventionalcommits.org/).
- Non-trivial architecture decisions require an [ADR](docs/adr/README.md).

Workflow details: [ADR 0003](docs/adr/0003-git-workflow.md).
