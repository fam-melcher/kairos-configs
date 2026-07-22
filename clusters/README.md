# Clusters

One directory per cluster (ADR 0012), named after the **first segment of
the cluster's DNS name** (`clusters/k8s-prod` ⇔
`k8s-prod.home.fam-melcher.net` — enforced by CI):

```text
clusters/<name>/
├── config/          # 11-cluster.yaml (THE cluster values, ADR 0013) + cluster-specific extras
├── nodes/           # one directory per node of this cluster
└── secrets/         # SOPS-encrypted material only (per-cluster age recipients)
```

**Single source of values (ADR 0013):** a cluster's values live exactly
once, in `config/11-cluster.yaml` — a pure data file (`values: {vip, dns,
…}`). The installer's dispatcher converts the scalars generically to
`/etc/kairos-cluster/cluster.env` on the node; everything that needs them
(tls-san drop-in, join target, kube-vip manifest) renders from there via
the shared renderers in `configs/cluster/`. Changing a VIP is a one-line
edit.

Create a new cluster with `scripts/add-cluster.sh <dns-name> <vip>` — it
scaffolds the directories, renders the config fragments from
`templates/cluster/`, generates the cluster age key, appends the sops
creation rule, and writes a fresh encrypted k3s token. Never build a
cluster by hand-copying another one.

Secrets: only `*.sops.yaml` files may exist under `clusters/<name>/secrets/`
(`.gitignore` blocks everything else). Recipient changes: edit `.sops.yaml`,
then `sops updatekeys clusters/<name>/secrets/*.sops.yaml`. Strategy:
docs/adr/0005-secret-management.md.

## Nodes

Each node directory `clusters/<cluster>/nodes/node-<id>/` (node ID per
ADR 0010) contains:

- `20-<node-id>.yaml` — node-specific cloud-config fragment (hostname,
  install device, network)
- `fragments.list` — ordered list of the node's permanent fragments; read
  by the installer's dispatcher (ADR 0008). Whether the node initialises
  the cluster or joins it is decided by the installer at install time
  (ADR 0011) and is deliberately absent from this list.

> Node definitions describe permanent node configuration only. Bootstrap
> role selection is an installer-time decision and must never be encoded
> in node state.

`scripts/validate-nodes.sh` (run by CI) rejects any `fragments.list` that
references a bootstrap fragment.

## Adding a node

1. Read the machine's product UUID (`cat /sys/class/dmi/id/product_uuid`,
   or Hyper-V: `Get-CimInstance -Namespace root\virtualization\v2
   Msvm_VirtualSystemSettingData | Select ElementName, BIOSGUID`).
2. `scripts/add-node.sh <cluster> <uuid> [install-device]` — scaffolds the
   node directory from the templates.
3. Review the generated files (network section), commit, push.
4. Boot the machine from the cluster's installer ISO — it selects this
   configuration by itself.

## Unknown UUID

Just boot the machine from the installer ISO. The live system announces
itself via DHCP as `setup-<id>` (visible in the switch/router UI; installed
nodes use `node-<id>`, so waiting machines are easy to tell apart — and a
disappearing `setup-` entry means the installation finished and the machine
powered off). The console shows a status screen with the node ID, the
branch/cluster this ISO serves, and the polled config URL; the dispatcher
polls the repository every 60 seconds.

Run `scripts/add-node.sh <cluster> node-xxxxxxxx`, commit, push — the
machine picks up its configuration on the next poll and installs without
another boot. Machines without a repository entry never install anything.
