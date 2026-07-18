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

## Creating a new ADR

1. Copy `template.md` to `NNNN-short-title.md` (next free number).
2. Fill in all sections; "Considered Alternatives" is mandatory.
3. Add the ADR to the index above.
4. Submit it together with the change it justifies.
