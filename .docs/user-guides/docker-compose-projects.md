# Docker Compose Projects

This guide describes the current tenant deployment workflow in the Vortex
panel and through `v-docker`. Docker Compose is the workload desired-state
format; Vesta owns authorization, policy, storage, routes, lifecycle
transactions, monitoring, backup, and audit.

## Fast path for an existing containerized application

Use this path when the application already has a Docker image and needs to run
as a tenant-owned project on a vesta-vxapp host. Do not copy a running
container, Docker data directory, or `docker inspect` output into Vesta. A
container is runtime evidence; the deployment inputs are an immutable image,
a policy-compliant Compose definition, and any separately managed data or
secrets.

Before the first deployment, the Vesta administrator must give the tenant an
interactive Bash shell, a positive or `unlimited` `DOCKER_PROJECTS` package
limit, sufficient resource quotas, SSH access, and the installed `v-docker`
broker. The tenant verifies that boundary without Docker or administrator
sudo:

```bash
ssh appuser@vesta.example.com \
  'command -v v-docker && v-docker quota json && v-docker projects json'
```

The application maintainer then:

1. Builds and tests outside the Vesta host, pushes to an approved registry,
   and resolves `registry/repository@sha256:<64-lowercase-hex>`.
2. Recreates the intended service definition in Compose. Add explicit CPU,
   memory, and PID limits; convert secret values to Vesta managed secrets;
   and replace arbitrary host paths with reviewed managed binds or named
   volumes.
3. Uses `add` when the project is absent from `v-docker projects`, or `change`
   only after `v-docker show PROJECT json` confirms the same owner and the
   `standard` profile.
4. Previews the local Compose bytes over SSH stdin, pulls every newly delivered
   immutable image using that exact preview tuple, explicitly approves, and
   applies before the preview expires.
5. Verifies health, any persisted workload probes, drift, routes, and backup
   readiness.

A minimal one-service definition has this shape:

```yaml
services:
  app:
    image: registry.example.com/team/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 512M
          pids: 256
```

For a first project, stream that file with `add` and use only the evidence
returned by the server:

```bash
preview_json="$(
  ssh appuser@vesta.example.com \
    'v-docker preview app add' < compose.yaml
)"

jq -e '
  .VALID == true
  and .OWNER == "appuser"
  and .PROJECT == "app"
  and .PROFILE == "standard"
  and .MODE == "add"
  and .EXPECTED_CURRENT_REVISION == 0
  and (.PREVIEW_ID | test("^[a-f0-9]{32}$"))
  and (.SOURCE_SHA256 | test("^[a-f0-9]{64}$"))
  and (.CANDIDATE_SHA256 | test("^[a-f0-9]{64}$"))
' <<<"$preview_json" >/dev/null

preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview_json")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview_json")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview_json")"
revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview_json")"
image='registry.example.com/team/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

ssh appuser@vesta.example.com -- \
  v-docker image-pull app "$preview_id" "$source_sha" \
  "$candidate_sha" "$revision" "$image"

# Apply only after reviewing the complete bounded preview result.
ssh appuser@vesta.example.com -- \
  v-docker apply app "$preview_id" "$source_sha" \
  "$candidate_sha" "$revision"

ssh appuser@vesta.example.com 'v-docker health app json'
ssh appuser@vesta.example.com 'v-docker drift app json'
```

Use the panel's simple **Add Container** flow instead when one service and its
safe generated Compose definition are sufficient. Use the advanced project
flow or SSH preview/apply when the application needs multiple services or an
application-maintained Compose file.

## Access and authority

- Open `/list/docker/` to view projects.
- A regular user sees and manages only their own projects with profile
  `standard`.
- An administrator selects an explicit owner and may use `standard` or
  `admin-approved`.
- Package limits cover projects, services, CPU, memory, PIDs, storage, ports,
  secrets, and volumes. A rejected quota check never deletes data.

`v-docker quota` reports those nine Compose workload dimensions. The optional
managed-Harbor artifact quota is separate and appears in `registry-info` only
after an eligible `standard` project exists.

Interactive shell access uses `v-docker`. It is enabled when the effective
package-derived `DOCKER_PROJECTS` value is positive (or `unlimited`) and the
Vesta account has an interactive Bash login. Vesta owns automatic
reconciliation of derived `vesta-compose-users` membership. A new login may be
needed before the shell displays a supplementary-group change, but the exact
`v-run-user-docker-command` broker checks live entitlement on every call, so
access changes apply immediately.

The broker derives your identity and permits only your own `standard`
projects. It does not accept owner or actor arguments. Administrator,
compatibility-profile, `admin-approved`, and privileged operations remain
excluded.
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

## Deploy from an application repository

A normal release is built outside the Vesta host and deployed by the same
tenant Unix/Vesta account that owns the `standard` project. The application
repository or CI system owns its build and deployment adapter; Vesta owns
authorization, image admission, immutable preview/apply, runtime convergence,
health, drift, routes, backup, and audit.

Before writing a deployment script, verify:

- the account has an interactive Bash shell and sufficient package
  `DOCKER_*` quotas;
- SSH public-key login works as the tenant and `v-docker quota json` succeeds;
- the account is not in the Docker group and cannot use the Docker socket;
- an external builder or CI runner supports the approved target architecture;
- an approved registry repository exists; and
- Compose contains no `build:`, mutable image tag, secret value, privileged
  setting, or arbitrary host path.

Registry publication and Vesta pull authentication are separate. The builder
uses its credential store to push. For a private registry, install the
tenant's pull credential once through bounded stdin:

```bash
printf '%s' "$REGISTRY_TOKEN" |
  ssh appuser@vesta.example.com \
    'v-docker registry-add registry.example.com deploy-user'
ssh appuser@vesta.example.com 'v-docker registries json' | jq .
```

Never put that token in argv, Compose, Git, logs, deployment JSON, or an
unencrypted artifact.

The optional Vesta-managed Harbor flow is different from an external registry
login. `registry-info PROJECT` requires an existing owner-scoped `standard`
project and does not create one. For a brand-new project, use an approved
public/external registry or an administrator-approved bootstrap path first.
After the administrator confirms the managed provider is healthy and fresh,
follow the [managed Harbor tenant guide](vesta-managed-harbor.md) for later
releases. Never infer provider readiness from the service merely being
installed.

For every release, the repository-owned script must:

1. Require a clean commit recoverable from a configured remote.
2. Build and test outside Vesta, push the release, and resolve the immutable
   `REGISTRY/REPOSITORY@sha256:<64-lowercase-hex>` reference.
3. Render policy-compliant Compose locally with that exact reference and only
   non-secret environment settings.
4. Query the target through `v-docker`; require the expected owner, project,
   `standard` profile, state, and revision. Use `add` only when the project is
   absent and expected revision is zero; use `change` for an existing project.
5. Stream Compose on SSH stdin to preview and validate every returned identity
   and evidence field without editing it.
6. Pull each newly delivered immutable image through the same preview tuple.
7. Require explicit approval before applying that exact tuple.
8. Require health, declared readiness probes, and drift match after apply.

The core update transaction is:

```bash
preview_json="$(
  ssh appuser@vesta.example.com \
    'v-docker preview app change' < rendered-compose.yaml
)"

jq -e '
  .VALID == true
  and .OWNER == "appuser"
  and .PROJECT == "app"
  and .PROFILE == "standard"
  and .MODE == "change"
  and (.PREVIEW_ID | test("^[a-f0-9]{32}$"))
  and (.SOURCE_SHA256 | test("^[a-f0-9]{64}$"))
  and (.CANDIDATE_SHA256 | test("^[a-f0-9]{64}$"))
  and (.EXPECTED_CURRENT_REVISION | type == "number" and . > 0)
' <<<"$preview_json" >/dev/null

preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview_json")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview_json")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview_json")"
revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview_json")"
image='registry.example.com/team/app@sha256:<64-lowercase-hex>'

ssh appuser@vesta.example.com -- \
  v-docker image-pull app "$preview_id" "$source_sha" \
  "$candidate_sha" "$revision" "$image"

# Run only after the deployment's explicit confirmation gate.
ssh appuser@vesta.example.com -- \
  v-docker apply app "$preview_id" "$source_sha" \
  "$candidate_sha" "$revision"

ssh appuser@vesta.example.com \
  'v-docker health app json' | jq -e '.STATUS == "healthy"'
ssh appuser@vesta.example.com \
  'v-docker drift app json' | jq -e '.MATCH == true'
```

When the current workload manifest declares a readiness probe, also require:

```bash
ssh appuser@vesta.example.com \
  'v-docker probe app ready json' | jq -e '.STATE == "pass"'
```

The adapter should support environment selection, `--dry-run`, an explicit
`--yes` or equivalent approval gate, and structured JSON. Progress belongs on
bounded redacted stderr. JSON stdout must not contain credentials, secrets,
complete environments, private-key material, or unredacted child output. Dry
run may build, resolve, render, and preview according to repository policy,
but it must not pull or apply.

### Deferring production deployment

An application may deliberately defer production while development delivery
is implemented and exercised. The adapter may validate the `production`
argument and non-secret configuration, but it must return a stable deferred
result before opening production SSH, creating a preview, pulling an image,
applying, or invoking any lifecycle operation. It must not silently redirect
production to development.

For example, a JSON adapter can return before network setup with a stable
result such as:

```json
{
  "ok": true,
  "code": "production_deferred",
  "environment": "production",
  "mutated": false,
  "message": "Production deployment is deferred by repository policy."
}
```

Removing deferral is a separate release decision. The production target,
immutable release, workload mutation, approval gate, and rollback/continuity
plan must be explicitly authorized. Development success never authorizes
production promotion.

Recurring deployments do not require an administrator or Debian SSH.
Administrator participation remains necessary for package/shell onboarding,
new managed bind leaves, privileged or compatibility profiles, protected
first installation of secret-dependent workloads, local archive admission,
and migrations. Deployment scripts must never fall back to raw Docker,
direct tenant sudo, administrator SSH, archive upload, or SCP/rsync of Vesta control
state. See the [complete source-to-Vesta runbook](../../DOCKER_ORCHESTRATION_DEPLOYMENT.md)
for package fields, an approval-separated reusable script, bootstrap, routes,
secrets, backup, rollback, and troubleshooting.

## Convert an existing container safely

When migrating a container from another host, reconstruct the intended
configuration from the application source and deployment records rather than
copying runtime internals:

- publish the image to an approved registry and use its immutable repository
  digest, never a container ID or mutable tag;
- translate ports to explicit Compose mappings and create Vesta routes
  separately;
- translate resource expectations to explicit CPU, memory, and PID limits;
- move durable application data into a reviewed managed bind leaf or managed
  named volume, with a backup before cutover;
- provision secret values through `v-docker secret-*`, never Compose
  environment, labels, commands, URLs, or health checks; and
- remove privileged mode, Docker socket mounts, host namespaces, devices,
  unsafe capabilities, arbitrary host paths, and host networking.

If the source is a legacy direct-container record already on this Vesta host,
the administrator can inspect `v-migrate-docker-containers USER dry-run` and
then run the explicit `apply` mode. That adapter is not exposed through
`v-docker`; a tenant must not emulate it with raw Docker or direct Vesta sudo.

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

## Managed secrets

Secret values use bounded stdin and are never Compose values or command-line
arguments:

```bash
printf '%s' "$DATABASE_PASSWORD" | v-docker secret-add app database-password
printf '%s' "$ROTATED_PASSWORD" | v-docker secret-change app database-password
v-docker secrets app json | jq .
v-docker secret-delete app database-password
```

Deletion is refused while the current revision still declares the secret.
The normal tenant `add` preview cannot atomically create a brand-new project
whose first revision requires managed secrets. That first installation uses
the protected administrator workload-bundle and secret-directory workflow in
the [complete runbook](../../DOCKER_ORCHESTRATION_DEPLOYMENT.md#8-secrets).
After bootstrap, the tenant can rotate declared values through `secret-change`.

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
retargeting. The current advanced editor does not provide route mutation UI,
but an eligible owner can use the brokered route commands. The domain must
already belong to the same Vesta owner, and the service/container port must
resolve to exactly one loopback-published TCP endpoint:

```bash
v-docker route-add app app.example.com web 8080 http /
v-docker deploy app
v-docker routes app json | jq .

v-docker route-delete app app.example.com
v-docker deploy app
```

Route metadata is staged separately from Compose; the following `deploy`
performs health, nginx validation/reload, and the bounded local route probe.

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

Tenant recovery and definition rollback use server-issued identifiers and
evidence:

```bash
v-docker backup app
v-docker backups app json | jq .
v-docker restore app BACKUP_ID validate
v-docker restore app BACKUP_ID apply

v-docker rollback-preview app REVISION
v-docker rollback-apply app REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA

v-docker reconcile-preview app
v-docker reconcile-apply app DRIFT_SHA CURRENT_REVISION
```

Restore accepts only a managed backup ID. Rollback changes the definition and
runtime, not persistent bind or volume data. After `remove app keep-data`, the
project no longer exists for owner-scoped restore; recovery then requires the
explicit operator workflow documented in the complete runbook.

## Current boundaries

The implementation does not provide Kubernetes/Swarm
scheduling, multi-host placement, arbitrary host access, privileged workloads,
automatic firewall changes, global Docker prune, managed-secret UI, route CRUD
UI, catalog deployment, Git/OCI synchronization, or automatic production
promotion.

See the [operator architecture guide](../../docs/container-orchestration.md),
[interface contract](../contracts/compose-interfaces.md), and
[self-service contract](../contracts/compose-self-service-deployment.md).
