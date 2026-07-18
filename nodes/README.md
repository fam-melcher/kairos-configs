# Nodes

One directory per node, named exactly like the node's hostname. Each
directory contains the node-specific cloud-config fragment `20-<hostname>.yaml`.

Adding a node:

1. `mkdir nodes/<hostname>`
2. Copy `templates/20-node.yaml.tmpl` to `nodes/<hostname>/20-<hostname>.yaml`
3. Replace every `@VARIABLE@` placeholder; no placeholder may remain.
4. Open a pull request.

The node's full configuration is the ordered set:
`configs/base/00-base.yaml`, `configs/roles/10-<role>.yaml`,
`nodes/<hostname>/20-<hostname>.yaml`. See docs/adr/0004.
