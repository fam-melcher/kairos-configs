# Secrets

Only SOPS-encrypted files (`*.sops.yaml`) may exist here; `.gitignore`
blocks everything else. Never commit plaintext secret material.

- Encrypt: `sops -e -i secrets/<name>.sops.yaml`
- Decrypt (to stdout only): `sops -d secrets/<name>.sops.yaml`
- Recipient changes: edit `.sops.yaml`, then `sops updatekeys secrets/*.sops.yaml`

Strategy and key handling: docs/adr/0005-secret-management.md.
