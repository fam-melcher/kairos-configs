# 0012 — Cluster directories, branch stages

- Status: Accepted
- Date: 2026-07-22

## Context

ADR 0009 encoded environments as branches: `main` carried production
values, `dev-vm-cluster` development values; env fragments, `.sops.yaml`,
and secrets were deliberately different per branch and never merged. That
made branches deployment targets, but it removed the normal git workflow:
no branch existed where a change could be tested before reaching
production, and every shared-file fix had to be cherry-picked between
branches that must never converge.

## Problem

How can changes be staged and tested before production without losing
per-environment configuration, secrets separation, and the
branch-as-deployment-target property of ADR 0008/0009?

## Considered Alternatives

1. **Keep environment branches, cherry-pick shared changes** — status quo;
   permanent divergence, no staging for shared files, error-prone.
2. **One branch, environments as directories, no staging branch** — solves
   divergence but every merge to `main` hits production machines
   immediately; no test stage.
3. **Branches are stages, directories are environments** — `main` = live,
   `dev` = staging; both branches carry all cluster directories. A change
   flows feature branch → PR → `dev` → tested on the dev cluster → PR →
   `main`. Environment values live in `clusters/<name>/`, identical in
   structure on every branch.

## Decision

Option 3.

- Layout: `clusters/<name>/{config,nodes,secrets}` per cluster; shared,
  environment-neutral fragments stay global (`configs/base`,
  `configs/roles`, `templates/`).
- **Naming rule**: the cluster directory name equals the first segment of
  the cluster's DNS name (`clusters/k8s-prod` ⇔
  `k8s-prod.home.fam-melcher.net`). Enforced by `scripts/validate-nodes.sh`
  in CI; held by construction when clusters are created with
  `scripts/add-cluster.sh`.
- Branch flow: `main` is what production machines poll; `dev` is the
  staging branch dev machines poll. Changes to `clusters/k8s-prod/` on
  `dev` are inert until merged — prod machines never read `dev`.
- ISO build (`scripts/build-iso.sh <branch> [cluster]`): builds are
  allowed from `main` and `dev` only. `main` requires an explicit cluster;
  `dev` defaults to `k8s-dev` but accepts any cluster (testing prod
  configuration from the staging branch). The dispatcher receives
  `CONFIG_BASE_URL` (branch) and `CLUSTER` (directory) and resolves all
  paths beneath `clusters/${CLUSTER}/`.
- Secrets: one `.sops.yaml` on every branch, one creation rule per cluster
  path — the dev ISO key can never decrypt prod secrets, now enforced per
  path instead of per branch. Cluster age keys live in `.keys/<name>.agekey`
  (untracked).
- Cluster scaffolding is a deliberate act: `scripts/add-cluster.sh
  <dns-name> <vip>` creates directories, renders config fragments from
  `templates/cluster/`, generates the age key, appends the sops rule, and
  writes a fresh encrypted k3s token. `add-node.sh` refuses unknown
  clusters and never creates one implicitly.

## Consequences

- Normal git workflow returns: one history, no cherry-picking, staged
  promotion feature → dev → main with CI on every PR.
- Both branches contain all clusters' configuration; reviewers must watch
  *which* cluster directory a PR touches — merging to `main` is still the
  deployment act for prod machines (unchanged from ADR 0008).
- Old installer ISOs (pre-0012 paths) 404-loop after the layout lands on
  their branch — safe (nothing installs), but ISOs must be rebuilt.
- The `dev-vm-cluster` branch is deleted; its values live on as
  `clusters/k8s-dev/`.

## Rationale

Directories can be merged, branches that must never converge cannot.
Moving the environment axis from branches into the tree restores the
staging workflow git is built for, while the poll-a-branch deployment
mechanism of ADR 0008 keeps working unchanged — the branch now expresses
*when* configuration goes live, the directory expresses *where*.
