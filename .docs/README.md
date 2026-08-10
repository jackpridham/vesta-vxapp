# Documentation Index

The Docker control plane is a single-host Vesta-owned Compose orchestrator.
Current documents:

- [Repository overview](../README.md)
- [Operator architecture and runbook](../docs/container-orchestration.md)
- [Complete source-to-Vesta deployment runbook](../DOCKER_ORCHESTRATION_DEPLOYMENT.md)
- [Vesta-managed Harbor operator runbook](user-guides/vesta-managed-harbor-operator.md)
- [Vesta-managed Harbor tenant deployment guide](user-guides/vesta-managed-harbor.md)
- [Vesta-managed Harbor registry specification](specs/2026-08-08-vesta-managed-harbor-registry.md)
- [Vesta-managed Harbor provider contract](contracts/harbor-provider.md)
- [Vesta-managed Harbor application release acceptance](validation/2026-08-11-slave-vxapp-managed-harbor-release.md)
- [Earlier Vesta-managed Harbor development attempts](validation/2026-08-08-vesta-managed-harbor-development.md)
- [Tenant Compose deployment guide — start here](user-guides/docker-compose-projects.md)
- [Native web-domain reverse-proxy guide](user-guides/native-web-domain-proxy.md)
- [Native web-domain proxy validation](validation/2026-08-06-native-web-proxy-release.md)
- [Self-service staging evidence](status/2026-07-29-compose-self-service-task7-staging-evidence.md)
- [Compose contracts](contracts/)
- [Compose tenant shell-access contract](contracts/compose-shell-access.md)
- [Application-neutral workload bundles](contracts/compose-workload-bundles.md)
- [Bounded managed-project probes](contracts/compose-project-probes.md)

## Document classes

- `contracts/` defines current non-negotiable behavior.
- `status/` records implementation state and chronological evidence.
- `validation/` contains dated environment or release-gate evidence; it is
  not standing deployment authorization.
- `plans/` records implementation intent and completed progress.
- `specs/` defines approved product behavior before implementation planning.
- `audits/` contains review inputs and findings from the named date and
  commit range.
- `user-guides/` contains current operator and user guidance.

Earlier `docker-*` schema contracts and the direct-container guide are
migration history and do not override current `compose-*` contracts.

## Readiness boundary

Vesta-managed Harbor's generated credential lifecycle is implemented and the
corrected development tenant lane passed a complete application release on
2026-08-11. The accepted path covered fresh discovery, encrypted publisher
rotation, external push, immutable preview-bound pull/apply, health, drift,
and public ingress. Production is still deferred. Harbor provider backup and
restore are disabled for
the first production release: both public commands return status 78 without
stopping Harbor or changing provider authority. Existing ciphertext and
provider data are retained. Recovery-key custody and re-enablement are tracked
in GitHub issue #2. The accepted first-release workload boundary stores no
durable application data outside cache. The tenant guide is the canonical
workflow after `registry-info` refreshes and confirms healthy, fresh managed
state.

The Compose implementation supports owner-only `standard` self-service,
immutable preview/apply, administrator-approved profiles, trusted image
delivery, managed backup and restore, and native Vesta ingress integration.
The workload-bundle and project-probe contracts define the protected generic
interfaces for application-owned release metadata and diagnostics.
Tenant interactive access is the `v-docker` client, derived
`vesta-compose-users` membership, and exact `v-run-user-docker-command`
broker. Package `DOCKER_PROJECTS` entitlement and interactive Bash are checked
live; Vesta owns automatic reconciliation. The surface is owner-equal,
standard-only, redacted, immutable for preview/apply, and accepts payloads
only through bounded stdin.
Production mutation always requires separate explicit authorization naming the
target, release, and workload scope.
Application repositories own external build/registry work and their deployment
adapter; recurring standard releases use tenant SSH plus preview-bound
`v-docker` pull/apply. A repository may defer production only by returning
before any production connection or workload operation.
