# Nodes

One directory per node, named after the node ID (ADR 0007):

```sh
node-$(cut -d- -f1 /sys/class/dmi/id/product_uuid | tr '[:upper:]' '[:lower:]')
```

Each directory contains:

- `20-<node-id>.yaml` — node-specific cloud-config fragment (hostname,
  install device, network)
- `fragments.list` — ordered list of all fragments this node is built from;
  read by the installer's dispatcher (ADR 0008). The role fragment named
  here decides whether the node initialises the cluster
  (`10-server-init.yaml`, exactly one node) or joins it
  (`10-server-join.yaml`).

## Adding a node

1. Read the machine's product UUID (command above, or Hyper-V:
   `Get-CimInstance -Namespace root\virtualization\v2
   Msvm_VirtualSystemSettingData | Select ElementName, BIOSGUID`).
2. `scripts/add-node.sh <uuid> [join|init] [install-device]` — scaffolds
   the node directory from the templates.
3. Review the generated files (network section), commit, push.
4. Boot the machine from the generic installer ISO — it selects this
   configuration by itself.

## Unknown UUID

Just boot the machine from the installer ISO. The dispatcher prints the
derived node ID on the console and polls the repository every 60 seconds:

```text
dispatch: no configuration for node-xxxxxxxx
dispatch: create nodes/node-xxxxxxxx/ in the repository — retrying in 60s
```

Run `scripts/add-node.sh node-xxxxxxxx`, commit, push — the machine picks
up its configuration on the next poll and installs without another boot.
Machines without a repository entry never install anything.
