# 0002 — Repository layout

- Status: Accepted
- Date: 2026-07-18

## Context

The repository must hold configuration for multiple Kairos nodes with
different roles (control plane, worker), heterogeneous hardware, and
different network segments. Nodes share most of their configuration; only a
small part is node-specific. Future additions (more nodes, new roles, CI,
image building) must fit without restructuring.

## Problem

How should directories and files be organised so that shared configuration
is defined once, node-specific configuration stays small, and the layout
survives growth?

## Considered Alternatives

1. **One full cloud-config per node (flat layout)** — simple to read per
   node, but every shared change must be copied into every node file.
   Guaranteed drift; violates the maintainability goal.
2. **Templating engine (Jinja2, ytt, gomplate) rendering per-node output** —
   powerful, avoids duplication, but introduces a toolchain dependency, a
   render step, and non-trivial debugging (what was actually deployed?).
   Overkill at the current scale.
3. **Layered fragments in one repository** — shared base, per-role, and
   per-node cloud-config fragments; a node's configuration is the ordered
   set of its three fragments. No render step, no duplication; relies on
   Kairos' native multi-file merge behaviour.

## Decision

Layered fragments (option 3) with this layout:

```text
configs/base/      shared fragment (00- prefix)
configs/roles/     one fragment per role (10- prefix)
nodes/<hostname>/  one directory per node, node fragment (20- prefix)
templates/         starting points for new node fragments
secrets/           SOPS-encrypted material only
scripts/           repository tooling
docs/              architecture documentation and ADRs
```

## Consequences

- Shared changes are made in exactly one place.
- A node's effective configuration requires looking at up to three files;
  the numeric prefixes make the merge order explicit.
- A future render/validation script can assemble fragments without layout
  changes (see ADR 0004).
- `secrets/` is isolated so ignore rules and SOPS rules can target it
  precisely (see ADR 0005).

## Rationale

Option 3 gives the deduplication benefit of templating without the
toolchain cost, and it maps directly onto how Kairos consumes cloud-config.
If placeholder substitution ever becomes genuinely necessary, a templating
layer can be added on top of this layout without breaking it.
