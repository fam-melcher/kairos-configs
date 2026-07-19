# 0009 — Branch and environment strategy

- Status: Accepted
- Date: 2026-07-19

## Context

The repository now serves two environments: a permanent development cluster
(Hyper-V VMs) used to test every non-trivial change, and the production
cluster on physical hardware. Installer ISOs fetch node configuration from
a branch at install time (ADR 0008), so branches are not just code lines —
they are deployment targets. Both clusters share one L2 network, so
cluster-wide values (VIP) must differ per environment, and a development
ISO key must never decrypt production secrets.

## Problem

How are branches, environments, and environment-specific files organised so
that changes flow from test to production without cherry-picking, and
environment values (nodes, VIP, secrets) can never leak across?

## Considered Alternatives

1. **Cherry-picking dev commits to main** — error-prone, requires rebase
   discipline, and the operator explicitly rejected the workflow overhead.
2. **Merging the dev branch into main** — carries dev nodes and dev
   environment values into production; every merge would need manual
   cleanup commits.
3. **Feature branches off main, tested via merge into dev** — the merge
   candidate for main is always the feature branch itself, never dev, so
   branch-specific files cannot leak.

## Decision

Option 3, with these rules:

- `main` = production. `dev-vm-cluster` = permanent development branch,
  never merged into main and never deleted.
- Every shared change starts as a feature branch **off main**, is merged
  into `dev-vm-cluster` for testing on the VM cluster, and reaches main
  exclusively through a pull request of the feature branch.
- **Branch-specific files** (never merged across environments):
  - `nodes/` — main carries only production nodes, dev only VM nodes;
    node directories are committed directly to their branch
  - `configs/env/` — cluster-wide environment values (VIP via K3s config
    drop-ins, join target, kube-vip manifest)
  - `secrets/` and `.sops.yaml` — per-environment cluster token and age
    recipients (prod VIP: 192.168.1.10, dev VIP: 192.168.1.11)
- Everything else (`configs/base/`, `configs/roles/`, `iso/`, `scripts/`,
  `templates/`, `docs/`) is environment-neutral and must stay free of
  environment values so merges remain conflict-free.
- Installer ISOs are environment-bound: `scripts/build-iso.sh` maps
  `dev-vm-cluster → dev` and `main → prod` (config URL, cluster age key,
  ISO name `kairos-<version>-<arch>-<distro>-<env>.iso`) and refuses to
  build from any other branch.

## Consequences

- No cherry-picking; changes are tested on real VMs before reaching main.
- Environment leakage is structurally impossible as long as feature
  branches touch no branch-specific paths; reviews must enforce this.
- The role fragments lost their environment values to `configs/env/`;
  node `fragments.list` files grew by the env fragments.
- One-time bootstrap exception: the initial production baseline was
  squash-merged from the dev branch state (minus dev-specific files),
  because main predated this strategy.

## Rationale

Branches-as-environments matches how the installer consumes the repository.
Keeping the merge candidate disjoint from the environment branches removes
the whole class of "dev config reached production" accidents instead of
guarding against it with process discipline.
