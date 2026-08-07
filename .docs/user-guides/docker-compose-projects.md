# Docker Compose Projects

This guide describes the current Vortex panel workflow. Docker Compose is the
workload desired-state format; Vesta owns authorization, policy, storage,
routes, lifecycle transactions, monitoring, backup, and audit.

## Access and authority

- Open `/list/docker/` to view projects.
- A regular user sees and manages only their own projects with profile
  `standard`.
- An administrator selects an explicit owner and may use `standard` or
  `admin-approved`.
- Package limits cover projects, services, CPU, memory, PIDs, storage, ports,
  secrets, and volumes. A rejected quota check never deletes data.

Interactive shell access uses `v-docker`. It is enabled when the effective
package-derived `DOCKER_PROJECTS` value is positive (or `unlimited`) and the
Vesta account has an interactive Bash login. Vesta owns automatic
reconciliation of derived `vesta-compose-users` membership. A new login may be
needed before the shell displays a supplementary-group change, but the exact
`v-run-user-docker-command` broker checks live entitlement on every call, so
access changes apply immediately.

The broker derives your identity and permits only your own `standard`
projects. It does not accept owner or actor arguments. Administrator,
`admin-approved`, `slave-vxapp`, and privileged operations remain excluded.
Use the redacted, immutable interface; Compose input is accepted through
bounded stdin.

```text
v-docker quota json
v-docker projects json
v-docker show app json
v-docker health app json
v-docker logs app app 100
v-docker preview app change < compose.yaml
v-docker apply app PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
v-docker restart app
```

Use the IDs, digests, and revision returned by preview exactly. If the source,
project revision, entitlement, or policy changes, create a new preview. Shell
access never grants Docker daemon access or a route around Vesta policy.

## Create a project

Use one of two owner-scoped flows:

1. `/add/docker/` generates a constrained one-service Compose project from the
   simple container form.
2. `/add/docker/project/` accepts a complete `standard` Compose definition.

The advanced flow validates and canonicalizes the definition without changing
project or Docker state. Review the service, resource, port, and route impact,
then confirm deployment. Confirmation is bound to a short-lived root-owned
candidate, its source and canonical SHA-256 digests, and revision `0`; changed,
expired, or replaced previews are refused.

Do not place passwords, tokens, registry auth, or private keys in Compose
environment, command, labels, or health checks. The current self-service panel
does not create or rotate managed secrets.

## Update a project

Open the project from `/list/docker/`, then use the Compose editor. For a
`standard` project, Vesta revalidates the stored definition before safely
preloading it. Definitions containing managed-secret source lines are not
exported; use the protected administrator/CLI workflow instead.

Preview is non-mutating. Confirmation succeeds only if the project revision
still matches. A concurrent or stale confirmation is rejected. Vesta holds the
project lock through definition installation, deploy, health and route checks,
and rollback. If the candidate fails, the previous healthy definition and
runtime are reconverged; persistent application data is not rewound.

## Lifecycle and inspection

Project detail provides redacted health, services, image identities, routes,
metrics, alerts, logs, backups, audit, revisions, and last-operation state.
Available lifecycle actions include start, stop, restart, recreate, deploy,
rollback, backup, restore, and remove, subject to owner and profile authority.

The default view uses operator cards and tables. Raw response data remains
available under **Advanced JSON**. Published endpoints, project-managed routes,
and native Vesta ingress consumers are separate: ordinary owners see only an
ingress-consumer count, while administrators may see redacted domain metadata
and protected header names, never header values.

Deployment and rollback previews show revision and impact before mutation.
Desired/runtime drift must be reconciled explicitly from an immutable
observation. Typed operation state reports operation ID, progress, terminal
result, and the last operation. A delegated `viewer` can inspect redacted
project evidence but cannot call lifecycle, deploy, rollback, backup, restore,
reconcile, secret, or removal actions.

Long-running panel actions stream a terminal result. Secret values, registry
authentication, raw Docker configuration, unredacted Compose, caller
environment, and complete temporary command lines are never returned.

## Routes

HTTP routes are Vesta-owned metadata, not Compose labels. They can target only
an owned domain, project service, and container port and render through
`vx-proxy` after nginx validation and a bounded local probe.

Self-service preview reports routes that remain valid, become invalid, or need
retargeting. The current advanced editor does not provide route mutation UI;
use the authorized route command workflow described in the
[operator guide](../../docs/container-orchestration.md).

## Data, backup, and removal

- Control state:
  `/usr/local/vesta/data/users/<user>/docker-projects/<project>/`
- Managed bind data: `/home/<user>/docker/<project>/binds/`
- Managed volumes: `vx_<user>_<project>_<volume>`

Project removal retains managed bind and volume data by default. There is no
public purge-data command. Back up the project before destructive work and use
explicit restore for application-data recovery; definition rollback does not
roll back persistent data.

Administrators can configure a project backup policy with schedule, daily and
weekly retention, encryption requirement, replication adapter, freshness
threshold, restore-test interval, and typed alerts. `not-configured`,
`unavailable`, and failed replication are explicit non-success states; the
panel never treats a missing off-host target as success.

## Current boundaries

The single-host control plane and managed `slave-vxapp` workload are live on
production. The 2026-07-31 product corrections are staging-validated on a
recoverable release branch but are not production-promoted without separate
authorization. The implementation does not provide Kubernetes/Swarm
scheduling, multi-host placement, arbitrary host access, privileged workloads,
automatic firewall changes, global Docker prune, managed-secret UI, route CRUD
UI, catalog deployment, Git/OCI synchronization, or automatic production
promotion.

See the [operator architecture guide](../../docs/container-orchestration.md),
[interface contract](../contracts/compose-interfaces.md), and
[self-service contract](../contracts/compose-self-service-deployment.md).
