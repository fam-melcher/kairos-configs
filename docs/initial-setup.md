# Initial setup

Bootstrapping a working environment from nothing but this repository and
the key backup. Covers a fresh workstation and a fresh cluster.

## 1. Prerequisites

- git with SSH access to `git@github.com:fam-melcher/kairos-configs.git`
- `age`, `sops` (e.g. `brew install age sops`)
- a container engine with a running daemon — docker, podman, or nerdctl
  (`scripts/build-iso.sh` auto-detects)
- `dig` and `ssh` for headless provisioning

## 2. Clone and set up keys

```sh
git clone git@github.com:fam-melcher/kairos-configs.git
cd kairos-configs
mkdir -p .keys && chmod 700 .keys
export SOPS_AGE_KEY_FILE="$PWD/.keys/engineer.agekey"
```

`.keys/` is hard-gitignored; nothing in it is ever committed. Two
starting points:

### 2a. Existing setup — restore from backup

Restore the private age keys from the backup (password manager) into
`.keys/` — see `secrets/README.md` for the expected files. Verify:

```sh
sops -d secrets/k3s-token.sops.yaml   # must print the token
```

Continue with step 3.

(No backup, but the cluster still runs? That is a rotation, not a setup:
[key-rotation.md](key-rotation.md), scenario "all keys lost".)

### 2b. From zero — no keys, no cluster

Generate the full key set (engineer key plus one cluster key per
environment you will use):

```sh
age-keygen -o .keys/engineer.agekey
age-keygen -o .keys/homelab-prod-cluster.agekey
age-keygen -o .keys/homelab-dev-cluster.agekey     # if using the dev env
chmod 600 .keys/*.agekey
```

**Back the keys up now** (password manager) — they exist nowhere else,
and a lost engineer key means every secret becomes unreadable.

Then, on each environment branch (`main` via pull request,
`dev-vm-cluster` directly):

1. Put the new **public** keys (printed by `age-keygen`, or
   `age-keygen -y <file>`) into `.sops.yaml`: engineer key plus that
   environment's cluster key — never the other environment's.
2. Any pre-existing files in `secrets/` were encrypted for previous keys
   and are unreadable now — recreate them. Currently that is the K3s
   cluster token:

   ```sh
   printf 'k3s_token: %s\n' "$(openssl rand -hex 32)" > secrets/k3s-token.sops.yaml
   sops -e -i secrets/k3s-token.sops.yaml
   sops -d secrets/k3s-token.sops.yaml >/dev/null && echo ok
   ```

3. Commit `.sops.yaml` and `secrets/` together.

Cross-check before building anything: the dev cluster key must fail to
decrypt prod secrets, and vice versa.

## 3. Build the installer ISO

Branches are environments (ADR 0009): `main` = prod, `dev-vm-cluster` =
dev. The build refuses other branches.

```sh
git checkout main            # or dev-vm-cluster
scripts/build-iso.sh         # -> build/iso/kairos-<ver>-<arch>-<distro>-<env>.iso
```

The ISO embeds the environment's private cluster age key — treat it as
secret material, do not upload or share it (ADR 0008).

## 4. Provision the first node (cluster init)

Exactly one node per cluster carries the `init` role.

1. Write the ISO to a USB stick, boot the machine from it. Without a
   repository entry it installs nothing — it polls and announces itself.
2. Find it (headless): the machine appears as `setup-<id>` in DHCP/DNS.

   ```sh
   for i in {100..254}; do n=$(dig +short -x 192.168.1.${i} @192.168.1.1); \
       [[ "${n}" == setup-* ]] && echo "192.168.1.${i} ${n}"; done
   ```

3. Create its configuration and push (on the environment's branch):

   ```sh
   scripts/add-node.sh <id-or-uuid> init <install-device>
   git add nodes/ && git commit -m "feat: add node-<id>" && git push
   ```

   On `main` this goes through a pull request (ADR 0003/0009).
4. The machine picks the configuration up on its next poll (≤60 s),
   installs, and **powers off** — that is the completion signal. Remove
   the stick, power it on.
5. Verify: the VIP (see `configs/env/12-cluster.yaml` of the branch)
   answers, and on the node `sudo k3s kubectl get nodes` shows it `Ready`.

## 5. Join the remaining nodes

Same procedure with role `join`. Wait until the VIP answers before
booting join nodes — they register through it. etcd quorum reminder
(ADR 0006): 2 nodes tolerate no failure; go to 3 quickly.

## 6. kubeconfig for the workstation

```sh
ssh kairos@<node-ip> sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/homelab.yaml
# replace 127.0.0.1 with the VIP:
sed -i '' 's/127.0.0.1/<vip>/' ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
```

## References

- Adding nodes, unknown UUIDs: `nodes/README.md`
- Secrets and key handling: `secrets/README.md`, [key-rotation.md](key-rotation.md)
- Architecture and decisions: `docs/architecture.md`, `docs/adr/`
