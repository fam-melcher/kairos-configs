# 0003 — Git workflow and branching

- Status: Accepted
- Date: 2026-07-18

## Context

This repository describes infrastructure. A broken `main` can brick a node
reinstall at the worst possible moment. History must stay trustworthy: a
commit that was reviewed and merged must never change afterwards. The
project is maintained by one engineer today but should support more
contributors without changing the rules.

## Problem

Which branching model, commit convention, and history policy should the
repository enforce?

## Considered Alternatives

1. **Commit directly to `main`** — lowest friction, no review point, no
   protection against half-finished states on the branch every node install
   depends on.
2. **git-flow (develop/release/hotfix branches)** — designed for versioned
   software releases; pure overhead for a configuration repository that has
   no release cadence.
3. **Trunk-based with short-lived feature branches** — every change on a
   `feature/*` (or `fix/*`, `docs/*`) branch, merged into `main` via pull
   request; `main` is always deployable.

## Decision

Trunk-based development (option 3) with these rules:

- No direct commits to `main`. The single exception was the initial README
  commit that created the repository.
- Every change goes through a feature branch and a pull request.
- No force pushes, no history rewriting on any pushed branch.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).
- Branch names: `<type>/<short-description>`, e.g.
  `feature/add-node-templates`, `docs/update-secret-strategy`.

## Consequences

- Every change has a review point, even in single-maintainer operation
  (self-review of the diff before merge).
- History remains append-only and auditable.
- Conventional commit types make the log scannable and enable changelog
  tooling later.
- Slightly more ceremony per change; accepted as the cost of a trustworthy
  `main`.

## Rationale

The repository's failure mode is "reinstall fails because `main` was
broken". Trunk-based with PRs is the lightest model that keeps `main`
always-deployable; git-flow adds structure this project will never use.
