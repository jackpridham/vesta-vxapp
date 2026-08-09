# Vesta-Managed Harbor Registry Specification

## Context

Vesta currently owns tenant Docker authorization, immutable Compose
preview/apply, owner-scoped registry credentials, preview-bound image pulls,
runtime convergence, and audit. Application repositories must nevertheless
select and configure an external OCI registry before a tenant can publish an
image for recurring deployment. That external dependency is easy to
misinterpret as deployment authority that remains outside Vesta.

Harbor is an open-source OCI registry built on CNCF Distribution. It supplies
private projects, role-based access control, automation accounts, quotas,
auditing, vulnerability scanning, retention, garbage collection, a REST API,
metrics, and webhooks. Its REST API supports integration without making the
Harbor portal a second operator control plane.

This specification makes Harbor an optional Vesta-managed platform service.
Vesta installs and operates one pinned Harbor instance, provisions tenant
namespaces and credentials through Harbor's API, and connects the resulting
pull credential to the existing Compose registry boundary. Tenants continue
to deploy through `v-docker`; Harbor stores image content but never grants
workload mutation authority.

The initial target is Harbor v2.15.0 deployed by its supported Docker Compose
distribution. The selected release is pinned and verified; no interface in
this specification means "latest" at runtime.

## First-release amendments (2026-08-09)

- A root-owned, group-restricted Unix socket is the approved fixed local
  Harbor transport. It replaces a host loopback TCP listener and reduces the
  exposed host network surface without changing the public Vesta TLS origin.
- First-release recovery delivers encrypted, validated provider backups and a
  documented operator recovery procedure. Automated restore apply and
  automated version upgrade are deferred because they are destructive,
  release-specific workflows and are not required to operate the pinned
  registry safely. The reserved restore `apply` mode fails without decrypting
  or mutating state.
- Provider backup includes the encrypted Harbor recovery secrets needed to
  reconstruct the service. Derived integration and runtime robot credentials
  are deliberately not archived; a future applied recovery must recreate and
  transactionally validate those credentials from protected bootstrap
  authority. Publisher plaintext remains unrecoverable by design.

## Goals

- Make Vesta the only product surface an operator must use to install,
  configure, monitor, and back up the pinned registry service.
- Derive the registry origin from Vesta's existing hostname, panel TLS port,
  certificate, and ingress listener without adding DNS or a public port.
- Give every eligible Docker tenant a private, isolated image namespace and a
  self-service publishing credential without administrator SSH.
- Automatically give Vesta a separate pull-only credential so immutable
  preview-bound deployments require no manual `registry-add` setup.
- Let application deploy adapters discover their repository location from
  Vesta instead of requiring a provider-specific repository setting.
- Preserve all existing tenant identity, standard-profile, image admission,
  preview/apply, secret-redaction, lock-order, and production-authorization
  boundaries.
- Keep existing workloads running when Harbor is unavailable or undergoing
  maintenance.

## Non-goals

- Building application images on a Vesta workload host.
- Giving tenants Harbor administrator access, raw Harbor API access, raw
  Docker access, or Docker socket/group access.
- Automatically deploying an image when Harbor receives a push or webhook.
- Replacing the existing immutable digest and preview-bound image-pull
  contract with mutable tags.
- Removing support for external OCI registries such as GHCR or an independently
  operated Harbor instance.
- Creating a registry-specific DNS record, public listener, firewall rule, or
  independently managed TLS certificate.
- Harbor high availability, multi-region replication, or Kubernetes/Helm
  deployment in the first release.
- Treating Harbor as a tenant Compose project or including Harbor data in an
  ordinary tenant project backup.
- Automatically deleting image data when a Vesta user, package entitlement,
  publisher credential, or workload project is removed.
- Authorizing a production workload deployment. Production mutation remains a
  separate explicit release decision.

## Requirements

### R1: Platform-service boundary

Harbor shall run as a root-owned Vesta system service with a distinct Compose
identity, state root, network, and lifecycle. It shall not be represented in
`data/users/<user>/docker-projects`, charged as a tenant workload, reachable
through the tenant Docker socket boundary, or mutable through tenant Compose
commands.

Harbor failure, restart, backup, or upgrade shall not stop or recreate an
application container. Existing containers and locally available accepted
images remain usable subject to the existing Compose contracts.

### R2: Optional provider mode

A Vesta installation shall have exactly one of these explicit managed-provider
modes:

- `disabled`: no managed provider; existing external-registry behavior is
  unchanged; or
- `managed`: this host runs and administers Harbor.

The first release shall not implement active/active Harbor management or
cross-Vesta provisioning. Another Vesta host may consume the managed Harbor
endpoint through its existing external-registry interface, but automated
federation is a separate specification. Installation, disablement, and any
future endpoint migration are administrator-only, validated, and audited.

### R3: Pinned and verified installation

The managed provider shall install an exact supported Harbor release from a
fixed Vesta release manifest. The manifest binds the version, supported
upgrade predecessors, installer URL, release checksum, signature-verification
identity, and expected Harbor component image digests.

Installation shall verify the upstream release signature and checksum before
extracting or running content. It shall reject floating tags, an unverified
installer, unsupported architecture, insufficient prerequisites, unsafe
filesystem ownership, a non-FQDN Vesta hostname, an invalid or untrusted Vesta
certificate, an unavailable/incompatible Vesta panel TLS listener, or a route
collision with the exact registry/token locations before changing a running
service.

The installer may use a fixed root-owned, mode-`0700` release cache under
provider authority when external release download is unavailable. Cached
archive and bundle files are fixed-path mode-`0600` inputs and must pass the
same pinned checksum, offline signature identity, archive topology, generator,
and image-evidence validation as freshly downloaded artifacts. No caller may
select a cache path or bypass verification.

The initial release manifest shall target Harbor v2.15.0. Updating the pinned
version requires a reviewed Vesta source change and release validation.

### R4: Endpoint and TLS ownership

The registry origin shall be derived from Vesta's existing authoritative
server FQDN and current panel TLS listener port. On a standard installation it
is `https://<vesta-hostname>:8083`; if the administrator has already changed
the Vesta panel port through Vesta, the registry uses that current port. The
installer accepts no registry hostname or port argument and creates no DNS,
firewall, NAT, or certificate object.

Vesta's panel nginx listener shall continue to own public TLS. On that same
host and port it shall proxy only the exact Harbor OCI `/v2/` namespace and
the exact token-service route emitted in Harbor's authentication challenge to
a fixed root-owned, group-restricted Unix socket. Harbor shall use an external
URL equal to the derived Vesta origin. The Harbor portal, administrative API,
metrics, and every other Harbor route remain available only through protected
local transport; Vesta's CLI and panel are the remote administration surfaces.

The registry locations shall preserve the client `Host`, external scheme,
client address, `WWW-Authenticate`, upload location, and
`Docker-Distribution-Api-Version` behavior required by the OCI Distribution
protocol. An unauthenticated `/v2/` probe shall return the expected `401`
challenge, never anonymous private-project access.

The shared listener shall use separate upstreams, location handling, access
logs, connection/concurrency limits, and registry upload timeouts. It shall
strip Vesta cookies before proxying to Harbor, suppress Harbor `Set-Cookie`
responses, and ensure Docker `Authorization` headers can reach only the exact
registry/token locations. It shall reject path-normalization, encoded-path,
method, and location fallthrough into the Vesta panel or Harbor administration
surface. Logs shall never contain authorization headers, cookies, tokens, or
request bodies.

The existing Vesta certificate and renewal lifecycle remain authoritative;
Harbor receives no independent public certificate. Certificate replacement
shall reload the shared nginx listener and validate both the panel and an
authenticated registry probe before reporting success.

Because immutable image references include `hostname:port`, Vesta shall not
silently follow a hostname or panel-port change. `v-change-sys-hostname` and
`v-change-vesta-port` shall fail closed while managed provider mode is enabled.
Endpoint migration requires a separately planned compatibility workflow; an
empty provider may be disabled, changed, and reinstalled without purging
retained provider data.

### R5: Vesta-owned Harbor API adapter

Shared Harbor integration shall live in a focused Vesta helper layer. Every
API request shall use:

- a fixed root-owned, group-restricted Unix-socket endpoint;
- a least-privilege Harbor system robot identity;
- an allowlisted HTTP method and API path;
- schema-validated, bounded JSON request and response bodies;
- fixed connection and operation timeouts;
- an empty environment and fixed executable paths; and
- bounded, redacted error output.

The system robot credential shall be read from a root-owned, mode-`0600`
secret file or protected descriptor. It shall never appear in argv,
environment, process metadata, stdout, JSON, HTML, logs, audit, or an
unencrypted backup. A tenant shall never supply an API endpoint, project ID,
permission set, Harbor username, or system credential.

Installation shall establish unique Harbor bootstrap-administrator and Vesta
integration credentials. The bootstrap secret is retained only as protected
recovery authority and is not used for routine API calls. Harbor v2.15.0
commit `e2b5ce92728f86c4b02f6a9a667741c1e5b62678` ignores
`RobotCreate.secret`: its controller always generates a valid secret and the
create handler returns it once in `RobotCreated.secret`. Vesta shall consume
that response through protected descriptors and shall not attempt to select
or later refresh the secret.

After bootstrap, the least-privilege integration robot is the only routine API
identity. It is system-level with system scope `/` and wildcard project scope
`*`. Its exact system-scope grants are project create/list, quota read/update,
and system-volume read. Its exact wildcard project grants are project
read/update, repository read/list/pull/push, and robot create/read/list/delete.
Project wildcard scope grants no quota action. Those actions provision,
verify, and revoke project children. Harbor's robot RBAC catalogs
deliberately omit `robot:update`; integration and child update/refresh
attempts therefore return `403`. Routine Vesta lifecycle shall use create, verify, switch, and
delete only, never robot update/refresh or bootstrap-administrator fallback.
The installer shall verify these exact levels, scopes, and actions and disable
Harbor self-sign-up and non-administrator project creation before reporting
readiness.

### R6: Deterministic tenant namespace

Every eligible Vesta owner shall map to exactly one private Harbor project.
The namespace shall be derived by Vesta from the exact owner identity and
persisted in root-owned provider state. The external repository path is
returned by Vesta and is not reconstructed by application scripts.

The namespace algorithm shall be deterministic, lowercase, accepted by the
pinned Harbor version, collision-checked before creation, and independent of
caller input. The implementation shall use a readable `vx-<owner>` name when
the owner is directly Harbor-safe; otherwise it shall use `vx-u-` followed by
the full lowercase SHA-256 of the owner. Persisted mapping is authoritative
and shall prevent remapping an existing owner to a different Harbor project.

Projects are private, administrator-created, and tenant project creation in
the Harbor portal is disabled. Project API requests use only Harbor-supported
private metadata, exactly `{"public":"false"}`. Installation identity, owner,
and deterministic namespace mapping remain in protected Vesta state; Vesta
does not invent unsupported Harbor project metadata keys.

### R7: Registry package entitlement and quota

The Vesta package model shall add `DOCKER_REGISTRY_MB` and the corresponding
system-maintained `U_DOCKER_REGISTRY_MB` usage value. Shipped defaults are
`0`. A tenant is eligible to publish only when all ordinary `v-docker`
eligibility checks pass, `DOCKER_PROJECTS` is positive or `unlimited`, and
`DOCKER_REGISTRY_MB` is positive or `unlimited`.

Vesta shall configure the Harbor project quota from the effective
`DOCKER_REGISTRY_MB` value. Harbor's project usage is authoritative for
registry bytes; Vesta mirrors the bounded value for package and panel
reporting. `DOCKER_STORAGE_MB` continues to cover Compose definitions,
revisions, binds, and managed volumes and shall not be silently reused as a
registry quota.

A quota reduction below current Harbor usage shall fail before changing the
package or Harbor quota. `unlimited` maps to Harbor's supported unlimited
project quota. Usage-query failure shall fail closed for quota increases and
publishing changes but shall not stop running workloads.

### R8: Publisher credential lifecycle

An eligible tenant shall create or rotate one deterministic project-scoped
publisher generation with
`v-docker registry-publisher-rotate < age-recipient`. Stdin contains exactly
one bounded native X25519 age recipient, not a publisher secret. Stdin is at
most 128 bytes including at most one optional terminal LF. After removing that
optional LF, the recipient must match `^age1[ac-hj-np-z02-9]{20,}$` and pass
native X25519 decoding. Empty input, multiple recipients, SSH recipients,
plugin recipients, identities, passphrases, multiline input, any other
whitespace, control bytes, NUL, and oversize input are rejected before Harbor
mutation; Vesta never invokes an age plugin. The robot receives only OCI pull
and push within that tenant project. Harbor requires pull with push; no delete,
project administration, member, scanner-administration, or cross-project
permission is granted.

Vesta shall configure a Harbor robot prefix compatible with the existing
registry username validator, such as `vxrobot-`. Harbor returns a project
robot username in the exact form `PREFIX + PROJECT + "+" + ROBOT_BASENAME`.
The username is non-secret metadata. Harbor generates the publisher secret
and returns it once in the create response. Vesta shall verify that credential
and stream it directly to fixed-path age encryption for the supplied
recipient. Publisher plaintext shall never be written to a regular file,
Vesta state, a journal, backup, log, audit event, argv, or environment.

Successful stdout is only one complete ASCII-armored age ciphertext carrying
the generated publisher secret. It contains no surrounding human text,
JSON, username, or plaintext. Failed rotation emits no successful ciphertext.
The tenant decrypts outside Vesta and supplies the result to
`docker login --password-stdin`.

Each child create carries a unique non-secret Vesta candidate marker. Vesta
creates, verifies, atomically switches owner metadata, and deletes the prior
publisher child. If Harbor commits a create but the one-time response is lost,
the marked candidate is discoverable but its secret is unrecoverable; Vesta
deletes it and retry creates a fresh generation. Suspension, administrator
conversion, loss of shell/package eligibility, `DOCKER_REGISTRY_MB=0`, or
explicit publisher disable deletes the publisher child and validates a
subsequent `404`. Runtime pull authority and retained images are not removed
by publisher revocation.

User deletion shall revoke publisher access through validated child deletion
and place the Harbor project in retained state. Deletion of the Harbor project
and image content requires a separate administrator retention-expiry and purge
workflow outside this specification.

### R9: Runtime pull credential lifecycle

Vesta shall create a distinct project-scoped pull-only robot for each
provisioned owner. Harbor generates its one-time create secret; Vesta consumes
and stores the plaintext-equivalent through the existing protected owner
registry configuration because unattended immutable pulls require it. It is
never given to the tenant.

Runtime credential rotation shall be transactional: create a replacement
generation with a unique candidate marker, validate an authenticated manifest
request, atomically install the replacement in owner registry state, and only
then delete the old generation and validate its absence. A lost create
response causes deletion of the marked unrecoverable candidate. A failed
rotation preserves the last validated pull credential. Runtime lifecycle does
not update, refresh, or disable a robot.

The managed registry entry shall be marked as provider-managed. Generic
tenant `registry-change` and `registry-delete` operations shall reject changes
to that entry while continuing to support independently configured external
registries.

### R10: Tenant discovery interface

The tenant command surface shall add these owner-derived operations:

```text
v-docker registry-info PROJECT [json|plain]
v-docker registry-publisher-rotate < age-recipient
v-docker registry-publisher-disable
```

`registry-info` accepts a Vesta Compose project name only to construct the
repository path; it does not require that the workload project already exist.
It returns bounded non-secret fields including provider state, registry host,
tenant namespace, repository, publisher username, publisher enabled state,
effective quota, usage, and provider health/freshness. It never returns a
credential, Harbor system identifier, internal endpoint, or raw API error.

Application deployment adapters shall query `registry-info`, build and push
to the returned repository, resolve `REPOSITORY@sha256:DIGEST`, and continue
through the unchanged preview, preview-bound `image-pull`, apply, health,
probe, and drift sequence. The managed-provider path removes the need for an
application-specific image repository environment variable.

### R11: No deployment side channel

A Harbor push, scan, API call, webhook, or publisher credential shall never
create or change Vesta desired state and shall never pull, start, stop,
restart, recreate, route, or deploy a workload.

Harbor webhooks may produce bounded Vesta audit/observability events for
artifact push, deletion, scan completion, or policy failure. Webhook payloads
shall be authenticated, size-bounded, schema-validated, replay-resistant, and
treated only as evidence. Deployment remains an explicit tenant SSH
preview/pull/apply transaction using an immutable digest.

### R12: Administration and panel integration

Vesta shall expose administrator commands for install, provider
configuration, status, reconciliation, backup, restore validation, and
removal planning. Public commands remain thin adapters over shared
helpers and preserve normal Vesta human/JSON behavior and audit conventions.

The Vesta panel shall display provider mode, endpoint, pinned/running version,
component health, storage usage, backup freshness, certificate expiry,
project count, and reconciliation failures. Administrator mutations require
authentication, CSRF validation, escaped arguments, and the existing bounded
job workflow.

Tenant panel views may display only the same non-secret fields as
`registry-info`. Publisher plaintext and age recipients shall not be accepted
or displayed by the web panel in the first release; tenant publisher rotation
is a bounded-stdin CLI operation whose only successful output is
ASCII-armored age ciphertext.

### R13: Health, metrics, and audit

Managed mode shall enable Harbor's official metrics endpoint on its protected
internal service network.
Vesta shall consume bounded component health and usage observations and expose
fresh/stale/unavailable status without proxying arbitrary Prometheus queries.

Audit shall record provider lifecycle actions, owner/project reconciliation,
quota changes, publisher enable/disable/rotation, runtime credential rotation,
backup/restore, and API failures. Audit contains owner, operation, result,
bounded reason, provider version, and hashed external identifiers where
needed; it never contains credentials, authorization headers, raw payloads,
image-layer content, or unredacted Harbor output.

### R14: Backup, restore, and retention

Harbor provider backup is a system backup separate from tenant Compose
backups. It shall cover the exact pinned configuration, Vesta provider
mapping, Harbor database, registry blob storage or external-storage manifest,
certificate configuration, and encrypted Harbor recovery secrets. Derived
robot credentials are recreated and validated during a future applied
recovery instead of being copied into the provider archive.

The backup workflow shall place Harbor into a supported consistent state,
record hashes and version metadata, verify the database and storage snapshot,
encrypt secret-bearing material, and retain a last-known-good recovery point.
It shall support validation-only restore without changing the running
provider.

Automated restore apply is deferred from the first release. Its reserved
command mode shall fail closed without decrypting or mutating state. A future
applied restore requires explicit administrator confirmation, exact target
version compatibility, pre-restore backup, component-health verification,
sample authenticated manifest verification, owner mapping reconciliation,
transactional integration/runtime credential recreation, and an audit result.
It shall never delete tenant project data merely because a Vesta account is
absent after restore.

### R15: Future controlled upgrades and recovery

Automated version upgrade is deferred from the first release, which remains
pinned to Harbor v2.15.0. No first-release interface accepts a target version
or performs a database migration.

Upgrade shall support only an explicitly declared predecessor-to-target path.
Before migration Vesta shall verify capacity and release artifacts, prevent
new pushes, create and validate a complete provider backup, and report the
expected registry maintenance window. Existing application containers remain
untouched.

Vesta shall follow Harbor's supported configuration and database migration
sequence. It shall not claim that a database schema migration can be reversed
by restarting old containers. Recovery after a failed irreversible migration
requires the exact pre-upgrade configuration, database, and blob snapshot.
Success requires all Harbor components healthy, authenticated push/pull
checks in a disposable Vesta-owned test project, metrics freshness, and
provider reconciliation.

### R16: Removal safety

Provider removal shall default to plan-only. It shall report dependent Vesta
hosts, tenant projects, stored bytes, current pull credentials, accepted
workload revisions referencing the registry, backup freshness, and the exact
data that would be retained.

No command in the first release shall combine service removal with Harbor
project/blob/database purge. Disabling the provider removes no Docker image,
container, Vesta desired state, route, volume, bind, revision, or tenant
backup. A managed registry shall not be removed while an accepted workload
depends on an image available only from that registry unless an administrator
has established and validated replacement authority.

### R17: Documentation and application handoff

The operator architecture, deployment runbook, Compose image contract, shell
catalog, package documentation, and panel guidance shall distinguish:

- external registry credentials managed by the tenant;
- a Vesta-managed Harbor provider and automatically managed runtime
  credential; and
- immutable Vesta deployment authority.

Documentation shall include a provider installation/recovery runbook and a
framework-neutral application deploy-adapter sequence. It shall state that
Harbor stores artifacts while Vesta authorizes and applies workloads.

## Proposed Design

### System layout

The repository shall ship Vesta-owned provider helpers, adapters, installer
templates, systemd policy, nginx configuration, tests, and documentation. A
representative source layout is:

```text
func/vx/harbor/
  main.sh
  api.sh
  lifecycle.sh
  projects.sh
  credentials.sh
  quota.sh
  backup.sh

install/common/harbor/
  harbor.yml.template
  release-manifest.json
  compose.override.yaml

install/common/systemd/
  vesta-harbor.service
```

The administrator command surface is:

```text
v-install-harbor-registry
v-list-harbor-registry [json|plain]
v-list-harbor-registry-owners [json|plain]
v-sync-harbor-registry-owner USER
v-sync-harbor-registry-owners
v-backup-harbor-registry
v-restore-harbor-registry BACKUP_ID validate|apply
v-plan-disable-harbor-registry [json|plain]
v-disable-harbor-registry CONFIRMATION_TOKEN
```

Install derives the external origin from Vesta and accepts no hostname or port.
Install uses the release pinned by Vesta source and accepts no
caller-selected version or installer URL. Restore resolves `BACKUP_ID` under
the provider backup root and accepts no archive path; `apply` is reserved and
returns status 78 without decrypting or mutating state. The plan command issues
a short-lived confirmation token bound to the current provider/dependency
manifest; disable revalidates that immutable plan. Disable removes the Harbor
locations from Vesta's existing listener and stops the internal service while
retaining all provider data and configuration. No lifecycle command opens or
closes a public firewall port.

On a managed host:

```text
/usr/local/vesta/data/harbor/       root-owned Vesta provider authority
/var/lib/vesta-harbor/              Harbor database, job, and blob state
/etc/systemd/system/vesta-harbor.service
```

`/usr/local/vesta/data/harbor` is mode `0700`; authority and secret files are
regular, non-symlink, single-link, root-owned mode `0600`. Large mutable
Harbor data does not live in the Vesta source tree or a tenant control root.
The systemd service invokes only a pinned root-owned Compose definition and
uses a distinct Compose project name such as `vesta-harbor`.

### Provisioning state machine

Owner reconciliation uses these states:

```text
ineligible
  -> project-ready
  -> runtime-ready
  -> publisher-ready

publisher-ready -> publisher-disabled
runtime-ready   -> retained
```

Reconciliation is idempotent. It acquires the owner access lock before the
owner registry lock and never holds a tenant project lock while calling the
Harbor administrative API. Provider-global changes use a separate provider
lock. No lock order may invert the existing owner/project/registry order.

Partial provisioning may leave a private empty Harbor project but shall not
leave a credential reported as active before validation. A later reconcile
continues from protected state. Retained projects preserve runtime pulls and
artifacts while denying new tenant publishing.

### Credential flows

Publisher flow:

```text
developer supplies age recipient on bounded SSH stdin
  -> v-docker broker derives owner
  -> Vesta validates entitlement and locks owner
  -> Harbor API creates a marked pull+push child and returns one-time secret
  -> Vesta verifies, encrypts to recipient, switches metadata, deletes old child
  -> stdout is only ASCII-armored age ciphertext
  -> developer decrypts outside Vesta and uses docker login --password-stdin
```

Runtime flow:

```text
Harbor API creates marked pull-only generation and returns one-time secret
  -> Vesta validates a manifest request
  -> existing owner registry configuration is atomically updated
  -> old robot generation is deleted and absence is validated
```

Publisher and runtime credentials are never interchangeable. The publisher
cannot mutate Vesta. The runtime credential cannot push to Harbor. Neither
lifecycle uses robot update or refresh. Publisher plaintext is never durable
on Vesta; runtime plaintext-equivalent remains Vesta-owned for unattended
pulls.

### Deployment data flow

```text
application adapter
  -> v-docker registry-info PROJECT
  -> local/CI build and tests
  -> authenticated Harbor push
  -> resolve repository@sha256:digest
  -> v-docker preview PROJECT add|change < compose.yaml
  -> v-docker image-pull exact protected tuple and digest
  -> v-docker apply unchanged tuple
  -> health, declared probes, and drift verification
```

The Harbor provider changes discovery and credential provisioning only. Image
manifest admission, protected `registry-pull` provenance, Compose policy,
expected revision, convergence, rollback, and audit remain owned by the
existing Vesta transaction.

### Provider topology

The initial operational topology is one central Harbor endpoint. It may be
co-located on a sufficiently resourced Vesta host as a system stack; it does
not require a separate product or tenant. Client Vesta hosts use the same
public HTTPS registry endpoint and owner-specific runtime credentials.

Co-location is not represented as high availability. Host loss can prevent
new pushes and missing-image pulls, so provider backups must be stored off the
managed host. Existing workloads continue because Harbor is outside their
runtime process and network dependency after image pull.

The public origin is always Vesta's existing hostname and panel port. Harbor
adds protocol locations to that listener but no TCP socket, firewall rule,
DNS record, NAT mapping, or certificate. Its host-facing backend is only the
root-owned, group-restricted Unix socket.

### Harbor API and portal usage

Vesta uses Harbor's REST API for project creation, quota configuration, robot
account lifecycle, repository/artifact observations, health, and maintenance
controls supported by the pinned release. Vesta does not scrape the Harbor
portal or depend on unstable HTML.

The Harbor portal remains a local-only emergency administrator diagnostic.
It is not the tenant onboarding, package, credential, or deployment interface.
Vesta state remains authoritative for owner eligibility and mapping; Harbor
state is authoritative for registry artifacts and measured project usage.

## Interfaces and Data

### Tenant registry information

Successful JSON output from `v-docker registry-info app json` has this stable
shape:

```json
{
  "MANAGED": true,
  "STATE": "ready",
  "REGISTRY": "server.example.com:8083",
  "NAMESPACE": "vx-appuser",
  "REPOSITORY": "server.example.com:8083/vx-appuser/app",
  "PUBLISHER_USERNAME": "vxrobot-vx-appuser+publisher",
  "PUBLISHER_ENABLED": true,
  "QUOTA_MB": 40960,
  "USED_MB": 8210,
  "HEALTH": "healthy",
  "OBSERVED_AT": "2026-08-08T03:00:00Z",
  "FRESHNESS": "fresh"
}
```

`QUOTA_MB` may be the string `unlimited`; all other numeric quota/usage values
are non-negative integers. `STATE` is one of `disabled`, `not-entitled`,
`provisioning`, `ready`, `publisher-disabled`, `retained`, or `unavailable`.
Health is one of `healthy`, `degraded`, or `unavailable`; freshness follows
the existing `fresh`, `stale`, or `unavailable` convention.

### Provider authority

Provider state records at least:

- schema version;
- provider mode and installation identity;
- derived Vesta hostname/panel-port origin and fixed internal endpoint;
- pinned and running Harbor versions;
- release-manifest hash;
- storage backend type and non-secret reference;
- tenant owner-to-project mapping;
- runtime robot generation metadata;
- project quota and observed usage;
- last reconcile, health, backup, restore-test, and upgrade state; and
- certificate expiry and observation time.

Secret values are stored separately from metadata. A different Vesta host
consuming this endpoint receives only the owner pull credential installed
through its existing external-registry boundary; it never receives the
managed host's bootstrap administrator or integration credential.

### Package and quota data

`DOCKER_REGISTRY_MB` appears in package, effective user, list, quota, and panel
surfaces alongside the existing Compose dimensions. `U_DOCKER_REGISTRY_MB` is
system-maintained from a recent Harbor observation and cannot be supplied by
a package or edited by a tenant.

A stale usage observation is clearly identified and cannot authorize a quota
reduction or new publisher credential. Staleness does not revoke an already
validated runtime pull credential.

## Failure Handling and Security

- Harbor unavailable: new pushes, provisioning, credential rotation, and
  missing-image pulls fail with a bounded provider-unavailable result. No
  workload or route mutation is attempted as a fallback.
- API timeout or malformed response: fail closed, retain prior validated
  credential/state, and append a redacted failure audit event.
- Partial project creation: keep the private project disabled for publishing
  and reconcile idempotently; never grant broad temporary permissions.
- Publisher rotation interrupted: Vesta preserves the prior validated
  generation unless the metadata switch completed. A committed create with a
  lost one-time response is found by its candidate marker and deleted. The
  caller may repeat rotation with the same or a new age recipient; Vesta never
  reports success before Harbor confirms the exact child permissions and
  produces one complete ciphertext.
- Runtime rotation interrupted: retain the old validated credential until the
  replacement passes an authenticated check and is atomically installed. A
  marked candidate whose create response was lost is deleted because its
  secret cannot be recovered.
- Push succeeds but deploy fails: the immutable artifact remains in Harbor;
  Vesta desired/runtime state follows normal preview/apply rollback rules.
- Registry quota exceeded: Harbor rejects additional content; Vesta reports
  current quota/usage and performs no workload mutation.
- Webhook duplicated or forged: reject authentication/replay/schema failure;
  accepted duplicates remain evidence-only and idempotent.
- Upgrade failure: keep workloads untouched, preserve the maintenance state,
  and restore only through the exact validated pre-upgrade recovery point.
- Backup failure: block upgrade and destructive provider actions; do not stop
  workloads or remove the last-known-good backup.

Tenant inputs never select another owner, namespace, provider endpoint,
Harbor role, or API path. Harbor plaintext credentials never appear in
Compose, application environment metadata, Docker labels, Vesta audit, web
pages, or unencrypted backups. Publisher plaintext is never durable on Vesta;
the command's sole credential-bearing output is its complete ASCII-armored age
ciphertext. Registry operations use the same bounded-stdin and redacted-output
rules as the existing Compose shell contract.

## Compatibility and Migration

The feature is opt-in and initially `disabled`. Deployments using external
registries continue unchanged. Existing `registry-add`, `registry-change`,
and `registry-delete` behavior remains available when the provider is disabled
and for non-provider-managed entries on a managed host.

Rollout order is:

1. ship provider state, package fields, API adapter, lifecycle commands, and
   tests with provider mode disabled;
2. install Harbor on a development managed host and validate backup/restore;
3. configure the development Vesta host as managed and provision a disposable
   tenant;
4. migrate one existing development tenant by pushing its next image to the
   Vesta-managed repository and using ordinary preview/pull/apply;
5. update application deployment documentation and remove repository-specific
   registry location settings only after discovery is accepted;
6. allow a production Vesta host to consume the registry through the existing
   external-registry boundary only after explicit production release
   authorization, backup validation, immutable image availability, and
   continuity/rollback review. Automated cross-host federation is deferred.

No existing container is rebuilt, restarted, relabeled, or re-created merely
to enable the provider. Existing accepted revisions retain their current image
evidence. Migration occurs on a normal future release by changing the image
repository and digest through preview/apply.

## Testing and Acceptance Criteria

### AC-R1/R2: Service isolation and modes

- In `disabled` mode, all existing external-registry and Compose tests produce
  unchanged results.
- Harbor has a distinct system Compose identity and cannot be listed, changed,
  stopped, or removed through any tenant project command.
- Restarting Harbor leaves a running disposable tenant workload unchanged.
- Managed mode rejects conflicting or multiple local authorities.

### AC-R3/R4: Installation and endpoint

- A verified pinned Harbor v2.15.0 release installs idempotently on a
  supported disposable Debian host.
- Corrupted checksum, invalid signature identity, floating version, unsafe
  path, non-FQDN hostname, route collision, incompatible panel listener, or
  invalid certificate fails before service replacement.
- Installation derives the exact Vesta hostname and current panel port without
  accepting either value from the caller. A standard host reports
  `<hostname>:8083` through `registry-info`.
- Firewall, DNS, NAT, and certificate state are unchanged by install, update,
  disable, backup, and restore validation; the set of externally listening
  addresses and ports is also unchanged.
- The existing Vesta listener passes authenticated OCI push/pull over trusted
  HTTPS; Harbor's backend listener is unreachable off-host and no additional
  public listening socket exists.
- Unauthenticated `/v2/` returns `401` with the expected authentication
  challenge and Distribution API header. An authenticated private-project
  push/pull succeeds through the same origin.
- Harbor portal, API, metrics, catalog administration, and non-allowlisted
  token/service routes are unreachable externally. Encoded, normalized,
  doubled-slash, invalid-method, and location-fallthrough probes cannot reach
  either Harbor administration or a Vesta panel action.
- Vesta cookies are absent at the Harbor upstream, Harbor cannot set a client
  cookie, and Docker authorization is absent from every panel upstream and
  log. Proxy and service logs contain no tested credentials, cookies,
  authorization headers, tokens, or request bodies.
- Vesta certificate renewal reloads the shared listener and leaves both panel
  authentication and registry push/pull healthy.
- `v-change-sys-hostname` and `v-change-vesta-port` reject unplanned changes
  while managed provider mode is enabled and leave the current origin
  operational.

### AC-R5/R6: API and namespace isolation

- API tests prove exact method/path allowlists, request/response size bounds,
  timeout handling, schema rejection, fixed endpoint use, and redaction.
- A network-free source-parity test pinned to Harbor v2.15.0 commit
  `e2b5ce92728f86c4b02f6a9a667741c1e5b62678` proves create-secret
  generation, one-time response disclosure, prefixed system/project names,
  wildcard subset delegation, secret-redacted reads, and `403` routine
  update/refresh behavior.
- Bootstrap creates the exact system integration robot once. Every routine
  project, quota, repository, and child lifecycle request authenticates as
  that integration robot; bootstrap-admin routine-call canaries fail.
- Two owners receive distinct private Harbor projects and cannot list, push,
  pull, or modify each other's private artifacts.
- Repeated reconciliation returns the same persisted namespace and does not
  create duplicate projects or robots.
- A Harbor-incompatible Vesta username receives the deterministic hashed
  namespace and the same mapping after backup/restore.

### AC-R7: Registry quota

- `DOCKER_REGISTRY_MB=0` denies publisher provisioning without affecting
  external registry credentials or running workloads.
- Positive and `unlimited` limits map to Harbor and appear in CLI/panel output.
- Harbor usage updates `U_DOCKER_REGISTRY_MB`; a reduction below usage is
  rejected before either authority changes.
- Stale/unavailable usage cannot authorize growth or reduction and is reported
  distinctly.

### AC-R8/R9: Credential boundaries

- A same-owner eligible tenant can rotate its publisher by supplying an age
  recipient through stdin, decrypt the returned ASCII-armored ciphertext
  outside Vesta, push within its namespace, and cannot administer or delete
  the Harbor project.
- Successful publisher-rotation stdout is exactly one ASCII-armored age
  ciphertext. Publisher plaintext is absent from durable files, Vesta state,
  argv, environment, stdout, JSON, HTML, logs, audit, process listings, and
  unencrypted backups.
- Suspension, package revocation, and explicit disable prevent subsequent
  publisher authentication while preserving running workloads and runtime
  pull evidence.
- Runtime children are pull-only and publisher children are pull-plus-push.
  Transactional rotation preserves the old credential on every injected
  pre-commit failure. Lost create responses leave only a marked candidate
  that is discovered, deleted, and validated absent.
- Routine lifecycle traces contain child create/read/delete and no robot PUT,
  PATCH, refresh, update, disable, or bootstrap-admin fallback. Every
  revocation is a successful delete followed by a not-found read while the
  project and artifacts remain.
- Generic registry change/delete rejects the provider-managed runtime entry
  but still manages a separate external registry.

### AC-R10/R11: Deployment pipeline

- A repository adapter obtains its complete image repository from
  `registry-info` without a provider-specific repository environment value.
- An eligible development tenant builds externally, pushes, resolves the exact
  digest, previews, pulls that digest, applies, and passes health/probe/drift
  through tenant SSH only.
- Pushing an image and delivering all supported webhook events causes no
  Compose, route, lifecycle, or Docker runtime mutation.
- Harbor outage after an image is already running does not interrupt the
  container; an unavailable missing-image pull fails before desired state
  mutation.

### AC-R12/R13: Operations and observability

- CLI and panel status agree on mode, endpoint, version, component health,
  usage, backup freshness, and certificate expiry.
- Every administrator mutation enforces authentication/CSRF as applicable and
  produces bounded audit without secrets.
- Health observations transition through fresh, stale, and unavailable
  without presenting old data as current.

### AC-R14/R15/R16: Recovery and lifecycle

- A complete provider backup validates its database, blob, mapping,
  configuration, encrypted recovery-secret, ownership, and digest inventory.
- Validation-only restore mutates no provider, workload, route, credential, or
  tenant data.
- Restore `apply` and any version-upgrade request fail closed without
  decrypting, migrating, or mutating provider or workload state.
- Removal planning reports every dependency and retained data item; no first
  release command purges Harbor data or tenant runtime state.

### AC-R17: Documentation

- A new application maintainer can identify the managed repository, configure
  a publisher, and implement external build/push plus Vesta preview/pull/apply
  using only Vesta documentation.
- Operator documentation covers installation, health, quota, backup, restore
  validation, upgrade, revocation, retention, and failure recovery without
  referring to a private application repository.

Release validation shall use focused tests during implementation and finish
with the repository-owned constrained gate:

```bash
test/compose/run-production-readiness-limited.sh
git diff --check
```

No broad standalone ShellCheck or unconstrained full readiness gate is
required on constrained hosts.

## Decisions and Trade-offs

### Selected: Harbor managed as a Vesta system service

This provides one operator product surface while preserving Harbor as an
upstream-supported isolated service. It reuses Harbor's registry, RBAC,
quota, audit, scanner, and API capabilities instead of rebuilding them in
Vesta.

### Rejected: Harbor as an ordinary tenant project

That creates a circular delivery and recovery dependency, exposes platform
lifecycle to tenant project controls, mixes provider data with tenant quota
and backup, and risks stopping the image source used to recover workloads.

### Rejected: Embedding a bare Distribution registry

CNCF Distribution is smaller, but Vesta would need to implement project
tenancy, robot credentials, quotas, audit, retention, scanning integration,
and substantially more lifecycle behavior. Harbor's additional internal
components cost memory and operational complexity but reduce custom security
surface.

### Selected: one central managed instance

This avoids requiring independent application-owned registries. Other Vesta
hosts may consume it through the existing external-registry boundary, but the
first release does not distribute Harbor administrative authority or invent a
cross-host control protocol. It does not claim high availability; off-host
backup and explicit outage behavior are therefore mandatory. Federation,
replication, and HA may be specified later without changing the tenant
deployment contract.

### Selected: Vesta's existing hostname and TLS listener

Using the current Vesta origin—normally `hostname:8083`—avoids a registry DNS
record, second public port, firewall mutation, and independent certificate.
It does not pretend that Harbor has no network attack surface: exact OCI and
token routes become reachable through the existing listener. Strict route,
header, cookie, logging, authentication, quota, timeout, and concurrency
boundaries therefore form part of the release contract. Harbor remains
reachable only through its protected local Unix socket and all non-registry
paths remain Vesta-owned.

### Selected: Harbor-generated child secrets with encrypted publisher delivery

The pinned Harbor controller generates every robot secret and returns it only
from create; it does not honor `RobotCreate.secret`. The tenant therefore
supplies an age recipient and receives only ciphertext, allowing the developer
to possess a push credential without making publisher plaintext durable on
Vesta. Vesta retains the runtime plaintext-equivalent because it alone needs
the pull credential for unattended immutable deployment. Separating the roles
prevents a compromised builder from changing Vesta or obtaining broader
registry access.

Harbor's robot RBAC catalog intentionally omits `robot:update`, so refresh and
update cannot be part of routine least-privilege lifecycle. Marked child
create, verification, metadata switch, and validated delete provide rotation
and revocation without bootstrap-admin fallback. A lost create response is not
recoverable; its marked candidate is deleted and a fresh generation is
created.

### Selected: separate registry storage quota

Registry artifacts and Compose persistent data have different accounting and
lifecycle. Reusing `DOCKER_STORAGE_MB` would permit ambiguous or double
allocation. A dedicated package field makes both limits observable and
enforceable.

### Selected: API integration, portal as diagnostics only

Harbor documents a REST API and Swagger explorer for administrative
integration. Using the API gives Vesta stable machine boundaries and avoids a
second tenant-facing UI. Webhooks remain evidence-only so image publication
cannot bypass explicit deployment approval.

## References

- [Harbor v2.15 documentation](https://goharbor.io/docs/main/)
- [Harbor REST API explorer](https://goharbor.io/docs/edge/working-with-projects/using-api-explorer/)
- [Harbor installation prerequisites](https://goharbor.io/docs/main/install-config/installation-prereqs/)
- [Harbor project robot accounts](https://goharbor.io/docs/2.12.0/administration/robot-accounts/)
- [Pinned Harbor robot controller](https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/controller/robot/controller.go)
- [Pinned Harbor robot API handler](https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/server/v2.0/handler/robot.go)
- [Pinned Harbor robot RBAC catalog](https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/common/rbac/const.go)
- [Harbor project quotas](https://goharbor.io/docs/main/administration/configure-project-quotas/)
- [Harbor metrics](https://goharbor.io/docs/main/administration/metrics/)
- [Harbor upgrades](https://goharbor.io/docs/main/administration/upgrade/)
- [CNCF Distribution nginx proxy guidance](https://distribution.github.io/distribution/recipes/nginx/)
- [CNCF Distribution deployment requirements](https://distribution.github.io/distribution/about/deploying/)
- [OCI Distribution API v2](https://distribution.github.io/distribution/spec/api/)
- [Compose images contract](../contracts/compose-images.md)
- [Compose shell-access contract](../contracts/compose-shell-access.md)
- [Compose self-service deployment contract](../contracts/compose-self-service-deployment.md)
