# 0017 — ArgoCD bootstrap: one-shot install, not a persistent HelmChart CR

- Status: Accepted
- Date: 2026-07-25

## Context

[ADR 0015](0015-argocd-bootstrap.md) staged ArgoCD via a k3s `HelmChart`
CR (`helm.cattle.io/v1`), reusing the mechanism this repo already
depends on for kube-vip and for disabling Traefik/servicelb. That CR is
not one-shot the way [ADR 0016](0016-one-shot-render-sentinel-fix.md)'s
other renderers are: it is a permanent Kubernetes object, continuously
reconciled by k3s's own `helm-controller` for the life of the cluster.

Once `kairos-gitops`'s `root` Application creates a second `Application`
that manages that same Helm release (`argocd-release` — self-management,
same pattern ArgoCD's own docs use for managing itself), the bootstrap
`HelmChart` CR and `argocd-release` become two independent, live
controllers reconciling the identical release simultaneously,
indefinitely. A follow-up fix (a `PostSync` hook deleting the `HelmChart`
CR once `argocd-release` first synced) treated this as a hand-off problem
to patch, not as a sign the bootstrap mechanism itself didn't match how
ArgoCD is meant to be installed.

That patch surfaced worse failures in practice, each one downstream of
the same root cause:

- The hook Job's image tag didn't exist (`bitnami/kubectl:1.31.4` — not
  a real tag).
- Fixed the tag; the hook then ran forever anyway — `kubectl delete
  --wait=true` (the default) needs `list`/`watch` on the target resource
  to confirm removal, and the hook's `ClusterRole` only granted
  `get`/`delete`. The delete succeeded immediately; the container never
  exited, because it could never confirm what already happened.
- Because it's a `PostSync` hook, that stuck container blocked
  `argocd-release`'s entire sync operation from ever completing —
  reproduced live: every single resource in the release showed
  `OutOfSync`, not because anything actually differed, but because the
  sync never reached completion to notice.
- Attempting to recover by force-deleting the stuck pod and clearing the
  Application's `status.operationState` directly (not an officially
  documented recovery method — verified after the fact: ArgoCD's
  documented mechanism is `argocd app terminate-op`) left ArgoCD's own
  bookkeeping for that release inconsistent. The next sync pruned the
  entire ArgoCD installation — with the bootstrap `HelmChart` CR already
  retired by the earlier hook, there was nothing left to bring it back
  except reinstalling the node.

Checked against ArgoCD's own documentation (previously assumed rather
than verified — see the standing rule this incident produced): the
official getting-started guide's install step is

```
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

— a one-time apply of static manifests. Nothing persistent reconciles it
afterward. There is no equivalent, anywhere in ArgoCD's documented
patterns, of a permanently-running second controller managing the same
installation ArgoCD itself later manages. The official self-management
example (same page) also requires `ServerSideApply=true` in
`syncOptions` explicitly: *"When managing Argo CD with Argo CD, you must
enable the `ServerSideApply=true` sync option"* — a requirement
`kairos-gitops`'s `argocd-release` Application did not have either.

## Problem

How should ArgoCD be bootstrapped on the genesis node so that handing
management over to `kairos-gitops`'s own self-managed `Application`
never involves two live owners of the same release, and never needs a
retirement step at all?

## Considered Alternatives

1. **Status quo plus a hardened retirement hook** (bounded
   `activeDeadlineSeconds`, correct RBAC, correct image) — fixes the
   specific bugs found, but keeps the persistent `HelmChart` CR as a
   second controller for the entire window between install and
   hand-off, and keeps a hand-off step ArgoCD's own documented patterns
   never need. Rejected: treats the symptom, not the mismatch with the
   documented mechanism.
2. **One-shot `kubectl apply --server-side` of ArgoCD's official install
   manifest, gated by the ADR 0016 sentinel pattern already used for
   every other genesis-only render in this repo.** No persistent second
   controller is ever created, so there is nothing to retire, ever.
   Matches the mechanism ArgoCD's own documentation uses. Chosen.

## Decision

- `configs/roles/16-argocd.yaml`'s boot stage, gated by
  `/oem/.rendered-16-argocd` (ADR 0016), now:
  1. Waits for the API server to answer (`kubectl get --raw /healthz`,
     bounded to 5 minutes) — this stage's ordering relative to
     `k3s.service` starting is not guaranteed, and community-documented
     experience with stuck ArgoCD hooks is unanimous that anything
     waiting on cluster state needs a deadline, not an assumption.
  2. Applies ArgoCD's pinned official install manifest
     (`https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/install.yaml`
     — `v3.4.5` matches the app version the previously-pinned argo-helm
     chart `10.2.0` itself deploys, confirmed via the chart's own
     rendered image tag) via `kubectl apply --server-side
     --force-conflicts`, checksum-verified against the actual published
     file before use (same posture as the checksum-verified sops/yq
     downloads in `scripts/build-iso.sh`).
  3. Applies the `root` Application the same way.
- `kairos-gitops`'s `argocd-release` Application gains
  `ServerSideApply=true` in `syncOptions`, matching ArgoCD's own
  documented self-management example exactly.
- `kairos-gitops`'s retirement `PostSync` hook
  (`base/argocd/retire-bootstrap-helmchart.yaml`) is deleted entirely —
  there is no longer a `HelmChart` CR for it to retire.

## Consequences

- No window, ever, where two controllers reconcile the same ArgoCD
  release — the failure class this ADR exists to close.
- One fewer moving part in `kairos-gitops`: no hook Job, no hook RBAC, no
  hand-off timing to reason about.
- The genesis node's boot stage now depends on network reachability to
  `raw.githubusercontent.com` during install — an existing assumption
  this repo already makes (`iso/dispatch.sh` fetches every fragment the
  same way), not a new one.
- Bumping ArgoCD's version now means updating two things that must
  agree: the argo-helm chart version `kairos-gitops`'s `argocd-release`
  targets, and this fragment's pinned install-manifest tag/checksum.
  Both already require a deliberate, reviewed change (same posture as
  kube-vip's pinned image tag, ADR 0006); a mismatch would surface
  immediately as ArgoCD reconciling itself to a different version than
  it was bootstrapped at, not silently.

## Rationale

The retirement-hook approach kept failing in new ways because each fix
addressed a symptom of the same mismatch: a persistent controller doing a
job ArgoCD's own documentation says should be a one-time apply. Once
verified against the actual documented mechanism instead of assumed from
general Helm/k3s reasoning, the fix collapses to reusing a pattern this
repo already trusts (ADR 0016's sentinel-gated one-shot render) instead
of building a second, novel piece of hand-off machinery to manage a
problem that a matching bootstrap mechanism doesn't create in the first
place.
