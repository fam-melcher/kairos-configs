# 0015 — ArgoCD bootstrap on the genesis node

- Status: Accepted (installation mechanism corrected by [0017](0017-argocd-bootstrap-one-shot-apply.md) — the decision to bootstrap ArgoCD on the genesis node, pointed at kairos-gitops, still stands)
- Date: 2026-07-23

## Context

`docs/architecture.md:10` scopes "workload deployment (manifests, Helm
releases, GitOps)" out of this repository, into a future separate repo.
That future repo, `kairos-gitops`, now exists — public, for the same
portfolio-visibility reason this repo itself is public. Something still
has to get ArgoCD running on a fresh cluster before that repo's content
takes over — a past attempt at this via Terraform failed in practice
because safely storing `tfstate` for a homelab-scale setup wasn't solved.

K3s ships a built-in `helm-controller` that reconciles `HelmChart` custom
resources (`helm.cattle.io/v1`) by running `helm install/upgrade`
internally — no external Helm binary, no state file, the reconciled state
lives in the cluster's own etcd. This repo already depends on this exact
mechanism: `configs/roles/10-server-init.yaml` and `10-server-join.yaml`
pass `--disable=traefik --disable=servicelb`, disabling two of k3s's own
default `HelmChart`-based addons.

Once any object is written to etcd via the API, it exists cluster-wide —
every node reads shared cluster state, not another node's local disk.
Applying a manifest once, from whichever node becomes `--cluster-init`,
is sufficient; nodes that join later see it through the API immediately.
`kairos-gitops` being public means ArgoCD needs no credential to read it.

## Problem

How does a fresh cluster get ArgoCD running and pointed at the GitOps
repo, automatically, without violating the reproducibility/security goals
this repo already holds, and without taking on ongoing workload-deployment
scope that `kairos-gitops` already owns?

## Considered Alternatives

1. **Manual day-2 step** (`kubectl apply` / `argocd` CLI, run once by a
   human after install) — no repo changes needed, but is exactly the kind
   of manual step `docs/architecture.md:22` ("Automation — no manual steps
   that a script can perform") argues against, and is easy to forget.
2. **Every node stages it redundantly**, mirroring how
   `configs/cluster/15-kube-vip.yaml` is listed in every node's
   `fragments.list` today — unnecessary here: unlike kube-vip's DaemonSet
   (needed *before* the cluster is reachable at all), ArgoCD only needs to
   exist once in etcd, and redundant `HelmChart` applies would trigger
   redundant `helm install` Jobs for no benefit.
3. **Genesis-node-only, checked-in template, boot-time render** — the
   node that probes and finds no cluster (ADR 0011) is also the only node
   that ever needs to stage this. Mirrors `configs/cluster/15-kube-vip.yaml`
   almost exactly: a real template file, `@TOKEN@` substitution from
   `cluster.env` at boot, one-shot self-delete (ADR 0014) — except fetched
   only in the genesis branch, the way `configs/cluster/13-join.yaml` is
   fetched only in the join branch.

## Decision

Option 3.

- `clusters/<name>/config/11-cluster.yaml` gains two values:
  `gitops-repo` (`https://github.com/fam-melcher/kairos-gitops`) and
  `gitops-path` (`clusters/<name>`) — pure data, same file, same
  conventions as `vip`/`dns` (ADR 0013). No dispatcher change needed to
  carry them into `cluster.env` — the existing generic scalar conversion
  already covers any new key (ADR 0013's own stated design goal).
- New checked-in fragment `configs/roles/16-argocd.yaml`, `BOOTSTRAP-ROLE`
  marked (installer-selected, ADR 0011), structured exactly like
  `configs/cluster/15-kube-vip.yaml`: a `files:` step stages a template
  with `@GITOPS_REPO@`/`@GITOPS_PATH@` placeholders, a `commands:` step
  sources `cluster.env`, `sed`-renders the `HelmChart` + root
  `Application` into `/var/lib/rancher/k3s/server/manifests/argocd.yaml`,
  and deletes its own `/oem/16-argocd.yaml` — the same one-shot pattern
  ADR 0014 established.
- `iso/dispatch.sh`'s genesis branch (where it already sets
  `role_fragment = configs/roles/10-server-init.yaml`) additionally
  fetches this fragment into `/oem` — mirroring exactly how
  `13-join.yaml` is fetched only for join nodes. No new function, no new
  captured variables: there is no secret to decrypt.
- `templates/cluster/11-cluster.yaml.tmpl` and `scripts/add-cluster.sh`
  gain the same two values, so future clusters get them for free the same
  way `vip`/`dns` already work.
- `docs/architecture.md`'s scope line is narrowed, not removed:
  provisioning the GitOps *controller* (installing the tool) stays this
  repo's job; what that controller deploys is `kairos-gitops`'s job,
  unchanged.

## Consequences

- A fresh cluster is `argocd`-reachable and already syncing from
  `kairos-gitops` with no manual step, no credential to manage or rotate.
- The false-genesis edge case ADR 0011 already accepts (a reinstalled
  node's install-time probe wrongly concluding "no cluster" during a
  network partition) now also bootstraps a second ArgoCD alongside the
  twin-cluster problem that scenario already causes. Not a new risk
  class, an extra symptom of one already accepted.
- ArgoCD's chart version is pinned in the template; bumping it is a
  one-line, deliberate change, same posture as kube-vip's pinned image tag
  (ADR 0006).
- `kairos-gitops` stays entirely responsible for everything past "ArgoCD
  exists and is pointed at the right path" — RBAC, `AppProject`s, further
  `Application`s, ingress, Vault, CI runners. This repo does not grow
  toward workload-deployment scope; it grows by exactly one bootstrap
  step.
- If `kairos-gitops` ever needs to go private (or gains a private
  overlay), this decision needs revisiting — a credential would have to
  be introduced then, via the same SOPS pattern already used for the k3s
  token. Not needed today.

## Rationale

Reuses two mechanisms this repo already trusts — k3s's built-in Helm
reconciliation (already load-bearing for disabling Traefik/servicelb) and
the checked-in-template-plus-boot-render pattern (already load-bearing for
kube-vip) — instead of introducing a third (Terraform, or a new manual
runbook). Being public removes the one piece that would have needed new
machinery (a credential), so this lands as close to free as a new
capability can land in this repo.
