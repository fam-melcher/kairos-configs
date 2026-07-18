# 0001 — Record architecture decisions

- Status: Accepted
- Date: 2026-07-18

## Context

This repository will manage Kairos configuration for a growing homelab over
years. Decisions about layout, workflow, and secret handling shape everything
built on top of them. Without written records, the reasoning behind such
decisions is lost and gets relitigated or silently violated later.

## Problem

How do we keep architecture decisions and their reasoning traceable over the
lifetime of the repository?

## Considered Alternatives

1. **No formal records** — decisions live in commit messages and heads.
   Cheap now, expensive later; reasoning is effectively lost.
2. **A single ARCHITECTURE.md changelog** — better than nothing, but grows
   unstructured and mixes current state with history.
3. **Architecture Decision Records (ADRs)** — one file per decision with a
   fixed structure, immutable once accepted, superseded explicitly.

## Decision

Every non-trivial architecture decision is documented as an ADR under
`docs/adr/`, numbered sequentially, using the structure in `template.md`
(Status, Date, Context, Problem, Considered Alternatives, Decision,
Consequences, Rationale).

Changing a decision requires a new ADR that supersedes the old one; the old
ADR is never deleted, only its status is updated.

## Consequences

- Small documentation overhead per structural change.
- New contributors (and future maintainers) can reconstruct why the
  repository looks the way it does.
- `docs/architecture.md` describes the current state; ADRs record how it got
  there.

## Rationale

ADRs are the established, low-ceremony standard for exactly this problem.
The cost is one short document per decision; the alternative costs are paid
repeatedly and invisibly.
