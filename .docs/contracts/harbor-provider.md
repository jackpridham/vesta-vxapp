# Vesta-Managed Harbor Provider Contract

This contract fixes the first-release authority, interfaces, persistence, and
concurrency rules for the optional Vesta-managed Harbor provider. Production
helpers must implement this contract without making Harbor a tenant workload
or a deployment authority.

## Command catalog

The administrator catalog is fixed:

```text
v-install-harbor-registry
v-list-harbor-registry [json|plain]
v-list-harbor-registry-owners [json|plain]
v-sync-harbor-registry-owner USER
v-sync-harbor-registry-owners
v-update-harbor-registry
v-backup-harbor-registry
v-restore-harbor-registry BACKUP_ID validate|apply
v-plan-disable-harbor-registry [json|plain]
v-disable-harbor-registry CONFIRMATION_TOKEN
```

The owner-derived tenant catalog is fixed:

```text
v-docker registry-info PROJECT [json|plain]
v-docker registry-publisher-change < publisher-secret
v-docker registry-publisher-disable
```

Install and update accept no hostname, port, release, or download URL. Restore
resolves `BACKUP_ID` below the provider backup root and accepts no archive
path. Disable consumes a short-lived token bound to the current plan and
retains provider data. Public commands are thin Vesta adapters over shared
`func/vx/harbor/` helpers.

## Filesystem and service layout

Repository paths map below `/usr/local/vesta` on a live host. Provider
authority is rooted at `/usr/local/vesta/data/harbor/`, mode `0700`, and is
separate from every `data/users/<owner>/docker-projects/` control root. Harbor
database, job-service, and blob data live below `/var/lib/vesta-harbor/`.
The root-owned unit is `/etc/systemd/system/vesta-harbor.service`; it invokes a
pinned root-owned Compose definition with the distinct project identity
`vesta-harbor`.

Authority and secret files are regular, non-symlink, single-link, root-owned
files. Metadata files are mode `0600`. Secrets are mode `0600`, stored
separately from metadata, and are never included in an unencrypted backup.
Provider backups are system backups outside tenant Compose backup roots.

Package quota transitions use `data/harbor/operations/<owner>.json`. Vesta
package and user state is desired authority. Before external Harbor mutation,
the command atomically publishes one secret-free operation containing exactly
the schema, idempotent operation ID, owner, desired package and quota,
`pending|converged|failed` state, bounded attempts, redacted last error, and
created/updated timestamps fixed by the implementation plan. Reconciliation
moves Harbor quota and Compose shell access forward toward desired state.

An interrupted or unavailable provider leaves the operation pending and does
not mutate workloads. Retry reuses the same operation ID. A bounded terminal
failure records `failed`; pending and failed operations block conflicting
package changes while the same desired operation may resume. There are no
transition HMACs, `user.conf` preimages, exchange/CAS machinery, package-trigger
compensation, or shell/group/disk rollback authorities.

## Provider and owner states

Provider mode is exactly `disabled` or `managed`. Owner reconciliation is
idempotent and follows:

```text
ineligible
  -> project-ready
  -> runtime-ready
  -> publisher-ready

publisher-ready -> publisher-disabled
runtime-ready   -> retained
```

An interrupted reconcile may retain a private empty project, but no credential
is active until validated and atomically recorded. `retained` preserves
artifacts and validated runtime pull authority while denying new publishing.
Removing a user, entitlement, publisher, or workload does not delete its
Harbor project or artifacts.

## Locks and external calls

The provider lock has shared and exclusive modes. The complete outer-to-inner
order is, verbatim:

```text
provider shared/exclusive lock
  -> owner access lock
    -> owner registry lock
      -> tenant project lock (only after every Harbor API call has returned)
```

Owner reconciliation never holds a tenant project lock while calling Harbor;
existing Compose keeps owner -> project -> registry ordering inside workload
transactions. Provider install/update/backup/restore/disable use exclusive
lock. Harbor-aware tenant/package/owner reconciliation takes shared provider
lock before owner lock; ordinary Compose operations do not take a provider
lock.

Deleted-owner tombstone replay uses the distinct fixed order `provider shared
lock -> Harbor tombstone owner-registry lock`. The second lock is a root-owned
mode-0600 file under `data/harbor/locks/`, derived only from the validated
tombstone owner. Replay never prepares or locks deleted `data/users/OWNER`
state. Existing-owner flows continue to use the normal provider -> owner
access -> Compose owner-registry order. Delete preparation extends that order
with the same Harbor tombstone owner-registry lock before publishing the
tombstone, preventing startup replay from racing publication or live-owner
credential mutation.

Managed package quota changes accept only owner observations no more than 300
seconds old and no more than 30 seconds in the future. The observation carries
an immutable generation and the authoritative quota setter treats owner and
operation ID idempotently while revalidating freshness for forward apply.
Provider startup and owner reconciliation source Compose access helpers, take
the shared provider lock before the owner access lock, and call package
transition recovery before other owner mutation.

No external Harbor request may occur while a tenant project lock is held.
Provider reconciliation that later needs a workload transaction must finish
all Harbor calls before acquiring that project lock and then obey the existing
Compose transaction order.

## Endpoint derivation and API boundary

The public registry origin is always derived from Vesta's authoritative FQDN
and current panel TLS port: `https://<vesta-hostname>:<panel-port>`. No caller
may supply either component. Vesta's existing nginx listener and certificate
remain authoritative and proxy only the exact OCI `/v2/` and emitted token
service routes. Harbor API, portal, metrics, and all other routes stay on a
fixed loopback-only endpoint.

The API adapter uses fixed executable paths, an empty environment, bounded
request and response bodies, fixed timeouts, Basic authentication loaded from
a protected file or descriptor, an allowlisted method/path pair, schema
validation, and bounded redacted errors. Tenants cannot select an endpoint,
API path, project ID, Harbor identity, or permission set.

## JSON schemas and enums

`registry-info PROJECT json` has these fixed keys:

```json
{
  "MANAGED": true,
  "STATE": "ready",
  "REGISTRY": "server.example.com:8083",
  "NAMESPACE": "vx-owner",
  "REPOSITORY": "server.example.com:8083/vx-owner/project",
  "PUBLISHER_USERNAME": "vxrobot-vx-owner+publisher",
  "PUBLISHER_ENABLED": true,
  "QUOTA_MB": 40960,
  "USED_MB": 0,
  "HEALTH": "healthy",
  "OBSERVED_AT": "2026-08-08T03:00:00Z",
  "FRESHNESS": "fresh"
}
```

`STATE` is exactly `disabled`, `not-entitled`, `provisioning`, `ready`,
`publisher-disabled`, `retained`, or `unavailable`. `HEALTH` is exactly
`healthy`, `degraded`, or `unavailable`. `FRESHNESS` is exactly `fresh`,
`stale`, or `unavailable`. `QUOTA_MB` is a non-negative integer or the string
`unlimited`; `USED_MB` is a non-negative integer. Booleans are JSON booleans.
The response never contains a credential, internal endpoint, Harbor system
identifier, or raw API error.

Provider state records a schema version, mode, installation identity, derived
origin and fixed internal endpoint, pinned/running versions, manifest hash,
storage backend reference, owner/project mappings, robot generation metadata,
quota and observed usage, reconcile/health/backup/restore-test/upgrade status,
certificate expiry, and observation timestamps. Persisted owner mapping is
authoritative. A Harbor-safe owner maps to `vx-<owner>`; otherwise it maps to
`vx-u-<full-lowercase-owner-sha256>`, with collision checks before creation.

## Authority and no-side-channel rule

Harbor is authoritative only for OCI artifact storage and measured project
usage. Vesta state is authoritative for provider mode, owner eligibility,
namespace mapping, credentials, package quota, accepted image evidence,
Compose desired state, revisions, routes, convergence, rollback, and audit.

A push, scan, Harbor API call, webhook, or publisher credential never creates
or changes Vesta desired state and never pulls, starts, stops, restarts,
recreates, routes, or deploys a workload. Webhooks are authenticated, bounded,
validated, replay-resistant evidence only. Deployment remains an explicit
tenant preview, immutable-digest pull, and apply transaction.

## Retention, backup, and disable behavior

Publisher revocation, lost eligibility, user deletion, workload deletion, and
provider disable retain projects and artifacts. No first-release command
combines service disablement with project, blob, or database purge. Disable
removes only managed listener locations and stops the provider service after
dependency-plan revalidation; it does not alter any image, container, desired
state, route, volume, bind, revision, tenant backup, or retained provider data.

Provider backup is separate from tenant backup and covers pinned
configuration, Vesta mappings, Harbor database and blob state (or an external
storage manifest), certificate configuration, and encrypted credentials. It
records hashes and version metadata, verifies database/storage snapshots, and
retains a last-known-good recovery point. Validation-only restore cannot
change the running provider. Applied restore requires explicit confirmation,
version compatibility, a pre-restore backup, health and authenticated manifest
checks, mapping reconciliation, and audit; account absence never causes
artifact deletion.
