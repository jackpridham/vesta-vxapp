# Documentation Index

The Docker control plane is a single-host Vesta-owned Compose orchestrator.
Current documents:

- [Repository overview](../README.md)
- [Operator architecture and runbook](../docs/container-orchestration.md)
- [Compose project user guide](user-guides/docker-compose-projects.md)
- [Native web-domain reverse-proxy guide](user-guides/native-web-domain-proxy.md)
- [Native web-domain proxy validation](validation/2026-08-06-native-web-proxy-release.md)
- [Self-service staging evidence](status/2026-07-29-compose-self-service-task7-staging-evidence.md)
- [Compose contracts](contracts/)

## Document classes

- `contracts/` defines current non-negotiable behavior.
- `status/` records implementation state and chronological evidence.
- `validation/` contains dated environment or release-gate evidence; it is
  not standing deployment authorization.
- `plans/` records implementation intent and completed progress.
- `audits/` contains review inputs and findings from the named date and
  commit range.
- `user-guides/` contains current operator and user guidance.

Earlier `docker-*` schema contracts and the direct-container guide are
migration history and do not override current `compose-*` contracts.

## Readiness boundary

The Compose implementation supports owner-only `standard` self-service,
immutable preview/apply, administrator-approved profiles, trusted image
delivery, managed backup and restore, and native Vesta ingress integration.
Production mutation always requires separate explicit authorization naming the
target, release, and workload scope.
