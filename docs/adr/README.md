# Architecture Decision Records

Every non-trivial architecture decision in this repository is recorded as an
ADR. ADRs are never deleted; superseded decisions are marked as such and
reference their replacement.

## Index

| ID   | Title                                                              | Status   |
|------|--------------------------------------------------------------------|----------|
| 0001 | [Record architecture decisions](0001-record-architecture-decisions.md) | Accepted |
| 0002 | [Repository layout](0002-repository-layout.md)                     | Accepted |
| 0003 | [Git workflow and branching](0003-git-workflow.md)                 | Accepted |
| 0004 | [Kairos configuration strategy](0004-kairos-configuration-strategy.md) | Accepted |
| 0005 | [Secret management](0005-secret-management.md)                     | Accepted |
| 0006 | [HA control plane topology with kube-vip](0006-ha-control-plane-topology.md) | Accepted (amended 2026-07-22) |
| 0007 | [Node identity derived from product UUID](0007-node-identity.md)   | Superseded by 0010 |
| 0008 | [Generic installer ISO with config self-dispatch](0008-installer-config-dispatch.md) | Accepted (amended 2026-07-22) |
| 0009 | [Branch and environment strategy](0009-branch-environment-strategy.md) | Superseded by 0012 |
| 0010 | [Node identity from hashed product UUID](0010-node-identity-hash.md) | Accepted |
| 0011 | [Zero-init bootstrap: installer-time role discovery](0011-zero-init-bootstrap.md) | Accepted (amended 2026-07-22) |
| 0012 | [Cluster directories, branch stages](0012-cluster-directories-branch-stages.md) | Accepted (amended 2026-07-22) |
| 0013 | [Single-source cluster values](0013-single-source-cluster-values.md) | Accepted |

## Creating a new ADR

1. Copy `template.md` to `NNNN-short-title.md` (next free number).
2. Fill in all sections; "Considered Alternatives" is mandatory.
3. Add the ADR to the index above.
4. Submit it together with the change it justifies.
