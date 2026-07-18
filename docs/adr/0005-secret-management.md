# 0005 — Secret management

- Status: Accepted
- Date: 2026-07-18

## Context

Provisioning Kairos nodes requires secrets before any cluster
infrastructure exists: the K3s cluster token, user password hashes, and
potentially Wi-Fi or VPN credentials. Later, cluster workloads will need
runtime secrets. The repository is hosted on GitHub; anything committed must
be assumed readable by the hosting provider and by anyone who ever gains
read access.

## Problem

How are secrets stored, encrypted, rotated, and access-controlled — today
for bootstrap, and later for runtime — without ever committing plaintext?

## Considered Alternatives

1. **Keep secrets out of git entirely (local files, password manager)** —
   no leak risk via the repository, but reinstalls stop being reproducible
   from the repository alone and manual steps multiply.
2. **git-crypt** — transparent file encryption, but all-or-nothing per key,
   no partial value encryption, weak rotation story, stagnant tooling.
3. **SOPS with age keys** — encrypts values inside YAML (structure stays
   diffable), multiple recipients per file, active ecosystem, native Flux
   integration later; age is a small, auditable dependency.
4. **HashiCorp Vault from day one** — strong runtime story, but requires
   running and securing a Vault before the first node exists
   (chicken-and-egg) and is heavy for a homelab bootstrap phase.

## Decision

Two-stage strategy:

- **Bootstrap secrets: SOPS + age (option 3), effective now.**
  - Encrypted files live in `secrets/` and match `*.sops.yaml`.
  - `.gitignore` blocks everything else in `secrets/`, so a plaintext file
    cannot be committed by accident.
  - `.sops.yaml` at the repository root defines creation rules; it ships
    with commented-out rules until the first age key is generated.
  - Private age keys live outside the repository (per-engineer, e.g.
    `~/.config/sops/age/keys.txt`); only public keys appear in `.sops.yaml`.
- **Runtime secrets: Vault or external-secrets operator (option 4), later.**
  - Introduced once the cluster runs; will get its own ADR.
  - Nothing in the current layout depends on its absence.

Operational rules:

- **Access control**: each engineer has an individual age key pair; access
  is granted/revoked by editing the recipient list in `.sops.yaml` and
  re-encrypting (`sops updatekeys`).
- **Rotation**: rotating a *key* = update recipients + `sops updatekeys`;
  rotating a *secret value* = change the value and rotate it at the consumer
  (e.g. K3s token rotation), tracked as a normal PR.
- **Decryption is local and ephemeral**: decrypted output goes to memory or
  ignored paths, never into the working tree as a tracked file.

## Consequences

- Reinstalls remain reproducible: repository + one private age key suffice.
- Secret changes are code-reviewed like any other change, with readable
  diffs of the file structure (values stay opaque).
- Compromise of the git hoster does not expose secret values.
- A later Vault integration replaces the *consumer* of runtime secrets, not
  this repository's layout.

## Rationale

SOPS+age is the de-facto standard for secrets-in-git at this scale: minimal
dependencies, per-value encryption, multi-recipient support, and a direct
upgrade path into GitOps (Flux/Argo both integrate SOPS). Vault stays on the
roadmap where it is strong — runtime secrets — instead of blocking bootstrap.
