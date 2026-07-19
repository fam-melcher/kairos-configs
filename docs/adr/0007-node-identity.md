# 0007 — Node identity derived from product UUID

- Status: Accepted
- Date: 2026-07-19

## Context

Node directories, hostnames, and the installer's config dispatch (ADR 0008)
need one stable, unique identifier per machine that can be read the same
way on any hardware. Role or location must not be encoded in the name —
they are repository assignments, not machine identity.

## Problem

Which machine property becomes the node identifier, and how is it derived?

## Considered Alternatives

1. **Sequential/assigned names (`cp01`…)** — robust, but carries no link to
   the machine; mapping must be maintained by hand and mistakes are silent.
2. **MAC address** — readable everywhere, but multi-NIC machines make the
   choice of NIC enumeration-dependent (the same nondeterminism that drove
   predictable interface naming). Rejected.
3. **`/etc/machine-id`** — regenerated on every reinstall; identity would
   not survive the reinstall it is supposed to make reproducible. Rejected.
4. **Disk WWN/EUI64 of the install disk** — deterministic (tied to the
   explicitly chosen install device), but identity changes on disk
   replacement and WWN exposure is unverified on some platforms.
5. **SMBIOS product UUID** (`/sys/class/dmi/id/product_uuid`) — stable
   across reinstalls, one canonical read path, independent of NIC/disk
   layout.

## Decision

Node ID = `node-` + first segment of the product UUID (the 8 hex characters
before the first dash), lowercase:

```sh
node-$(cut -d- -f1 /sys/class/dmi/id/product_uuid | tr '[:upper:]' '[:lower:]')
```

Example: UUID `291F6C15-…` → `node-291f6c15`. The ID names the node
directory (`nodes/node-291f6c15/`), the node fragment and the hostname.

## Consequences

- The installer derives the ID itself and selects its configuration without
  any per-machine ISO or manual mapping (ADR 0008).
- Eight hex characters are collision-safe at homelab scale; the full UUID
  remains available as a tie-breaker if a collision ever occurs.
- Mainboard replacement changes the identity — acceptable: such a machine
  is effectively new hardware and gets a new node directory.
- **Known limitation**: Apple Silicon machines expose no SMBIOS/DMI under
  Linux. Before ARM bare-metal joins the lab, this ADR must be extended
  (device-tree serial as fallback source) — tracked as an open point.

## Rationale

For the current fleet (QEMU/UTM VMs, x86 servers), the product UUID is the
only identifier that is uniform, stable across reinstalls, and free of the
enumeration nondeterminism that disqualified MAC addresses. The derivation
rule is trivial enough to run in a POSIX-shell installer environment.
