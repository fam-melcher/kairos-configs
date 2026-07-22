# Nodes

One directory per node, named after the node ID (ADR 0010):

```sh
node-$(cat /sys/class/dmi/id/product_uuid | tr -d '[:space:]' \
    | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-8)
```

Each directory contains:

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

1. Read the machine's product UUID (command above, or Hyper-V:
   `Get-CimInstance -Namespace root\virtualization\v2
   Msvm_VirtualSystemSettingData | Select ElementName, BIOSGUID`).
2. `scripts/add-node.sh <uuid> [install-device]` — scaffolds the node
   directory from the templates.
3. Review the generated files (network section), commit, push.
4. Boot the machine from the generic installer ISO — it selects this
   configuration by itself.

## Unknown UUID

Just boot the machine from the installer ISO. The live system announces
itself via DHCP as `setup-<id>` (visible in the switch/router UI; installed
nodes use `node-<id>`, so waiting machines are easy to tell apart — and a
disappearing `setup-` entry means the installation finished and the machine
powered off). The console shows a status screen and the dispatcher polls
the repository every 60 seconds:

```text
dispatch: no configuration for node-xxxxxxxx
dispatch: create nodes/node-xxxxxxxx/ in the repository — retrying in 60s
```

Run `scripts/add-node.sh node-xxxxxxxx`, commit, push — the machine picks
up its configuration on the next poll and installs without another boot.
Machines without a repository entry never install anything.
