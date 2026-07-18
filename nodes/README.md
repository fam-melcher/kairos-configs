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

1. Read the machine's product UUID and derive the node ID (command above).
2. `mkdir nodes/<node-id>`
3. Copy `templates/20-node.yaml.tmpl` to `nodes/<node-id>/20-<node-id>.yaml`
   and replace every `@VARIABLE@` placeholder (grep for `@` must come back
   empty).
4. Copy `templates/fragments.list.tmpl` to `nodes/<node-id>/fragments.list`
   and replace `@NODE_ID@`.
5. Open a pull request. After merge, boot the machine from the generic
   installer ISO — it selects this configuration by itself.
