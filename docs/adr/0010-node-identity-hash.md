# 0010 — Node identity from hashed product UUID

- Status: Accepted
- Date: 2026-07-19
- Supersedes: [0007](0007-node-identity.md)

## Context

ADR 0007 derived the node ID from the first segment of the SMBIOS product
UUID. Preparing the first physical production node exposed a flaw: Dell
encodes its vendor name into the UUID prefix — every Dell machine's UUID
starts with `4C4C4544` ("DELL" in ASCII). The first segment is therefore
vendor-constant, and a second Dell machine would collide with the first,
receiving the same node ID and the same configuration from the dispatcher.

## Problem

The identity derivation must use the machine-unique part of the product
UUID without depending on vendor-specific knowledge about which part that
is.

## Considered Alternatives

1. **Use a different UUID segment** (e.g. the last 12 hex digits) — fixes
   Dell, but relies on new assumptions about vendor encoding; other vendors
   may encode constants elsewhere.
2. **Hash the full UUID** — every bit of the UUID contributes; a truncated
   SHA-256 of the whole value is collision-safe at fleet scale regardless
   of vendor encoding.

## Decision

Node ID = `node-` + first 8 hex characters of SHA-256 over the lowercased,
whitespace-stripped product UUID:

```sh
node-$(cat /sys/class/dmi/id/product_uuid | tr -d '[:space:]' \
    | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)
```

Lowercasing before hashing is part of the contract: BIOS vendors differ in
UUID casing, and the same machine must always derive the same ID.
`scripts/add-node.sh` accepts a full UUID (and applies the same derivation)
or a ready-made `node-<8hex>` ID as displayed by the installer's status
screen.

## Consequences

- Node IDs are no longer visually related to the UUID; the status screen
  and DHCP name (`setup-<id>`) remain the authoritative way to read a
  machine's ID.
- Existing development nodes keep their ADR-0007-style IDs until their
  next reinstall (lazy migration): a reinstall derives the new hash ID,
  shows it on the status screen, and gets a fresh node directory via
  `scripts/add-node.sh`; the old directory and the stale k3s node object
  are removed manually.
- Installer ISOs built before this change derive old-style IDs and must be
  rebuilt.

## Rationale

Hashing removes the entire class of vendor-encoding surprises instead of
patching around the one vendor that surfaced it. Eight hex characters of
SHA-256 keep the collision probability negligible at homelab scale while
staying short enough for hostnames and console output.
