# Secrets

Only SOPS-encrypted files (`*.sops.yaml`) may exist here; `.gitignore`
blocks everything else. Never commit plaintext secret material.

Private age keys live repo-local in `.keys/` (working tree only, hard
gitignored, never tracked) so keys stay scoped to this project:

- `.keys/engineer.agekey` — engineer key, decrypts this repo's secrets
- `.keys/homelab-<env>-cluster.agekey` — per-environment cluster key,
  embedded into that environment's installer ISO (ADR 0008)

sops does not find repo-local keys on its own — set the key explicitly:

```sh
export SOPS_AGE_KEY_FILE="$(git rev-parse --show-toplevel)/.keys/engineer.agekey"
```

- Encrypt: `sops -e -i secrets/<name>.sops.yaml`
- Decrypt (to stdout only): `sops -d secrets/<name>.sops.yaml`
- Recipient changes: edit `.sops.yaml`, then `sops updatekeys secrets/*.sops.yaml`

The keys have no second copy — back up `.keys/` into a password manager or
an encrypted offline location. Losing the engineer key means losing access
to every secret; losing a cluster key means rotating recipients and tokens.

Strategy and key handling: docs/adr/0005-secret-management.md.
