# Key and secret rotation

Runbook for rotating the age keys and the secrets they protect. Key roles
and locations: `secrets/README.md`. Recipients are branch-specific
(ADR 0009) — every recipient change happens per environment branch.

Environment variable used throughout:

```sh
export SOPS_AGE_KEY_FILE="$PWD/.keys/engineer.agekey"
```

## Scenario 1 — rotate the engineer key

When: workstation lost or compromised, scheduled hygiene.

1. Generate the replacement:

   ```sh
   age-keygen -o .keys/engineer.agekey.new
   ```

2. On **each** environment branch (`main` via PR, `dev-vm-cluster`
   directly): replace the engineer recipient in `.sops.yaml` with the new
   public key, then re-encrypt:

   ```sh
   sops updatekeys -y secrets/*.sops.yaml
   ```

3. Swap the files, update the backup (password manager), verify:

   ```sh
   mv .keys/engineer.agekey.new .keys/engineer.agekey
   sops -d secrets/k3s-token.sops.yaml >/dev/null && echo ok
   ```

The cluster keys and ISOs are unaffected.

## Scenario 2 — rotate a cluster key (dev or prod)

When: an installer ISO or USB stick left trusted hands, key hygiene.
The cluster key can decrypt that environment's K3s token — rotating the
key without rotating the token leaves the leaked ISO able to join nodes
to the cluster, so both rotate together.

1. New key for the environment:

   ```sh
   age-keygen -o .keys/homelab-<env>-cluster.agekey.new
   ```

2. On the environment's branch: replace the cluster recipient in
   `.sops.yaml` with the new public key.
3. Rotate the K3s token on the running cluster (any server node):

   ```sh
   ssh kairos@<node> sudo k3s token rotate --new-token=<new-random-value>
   ```

   Generate the value with `openssl rand -hex 32`. Verify the cluster is
   healthy afterwards (`kubectl get nodes`).
4. Re-encrypt the repository secret with the new value and new recipients:

   ```sh
   printf 'k3s_token: %s\n' '<new-random-value>' > secrets/k3s-token.sops.yaml
   sops -e -i secrets/k3s-token.sops.yaml
   ```

5. Swap the key file, update the backup, commit/PR the branch changes.
6. Rebuild the environment's ISO (`scripts/build-iso.sh`) and destroy all
   old ISOs and sticks of that environment — they hold the old key.

## Scenario 3 — rotate only the K3s token

When: token exposure suspected, keys intact. Steps 3–4 of scenario 2,
then rebuild nothing (the ISO holds the key, not the token — it fetches
and decrypts the current token at install time).

## Scenario 4 — all keys lost (no backup)

Encrypted secrets are unrecoverable by design. Recovery works because the
cluster itself still runs:

1. Generate a full new key set (engineer + one cluster key per
   environment) into `.keys/`, back them up immediately.
2. Rewrite `.sops.yaml` recipients on both branches.
3. Read the current K3s token from a running server node
   (`sudo cat /var/lib/rancher/k3s/server/token`), rotate it
   (scenario 2 step 3), and encrypt the new value (scenario 2 step 4).
4. Rebuild all ISOs; destroy old media.

## After every rotation

- [ ] Backup updated (all `.keys/*.agekey` files)
- [ ] `sops -d` works with the new engineer key
- [ ] Cross-environment check: the dev cluster key must fail to decrypt
      prod secrets, and vice versa
- [ ] Old ISOs/sticks of the affected environment destroyed
- [ ] Cluster healthy: `kubectl get nodes`, VIP answering
