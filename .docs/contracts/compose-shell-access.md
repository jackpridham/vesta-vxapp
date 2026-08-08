# Compose Tenant Shell-Access Contract

Managed-registry discovery and publisher lifecycle are exact `v-docker`
subcommands. Identity is kernel/sudo-derived; callers cannot provide an owner,
Harbor endpoint, namespace, robot identity, or secret path. Publisher secret
input is bounded stdin and never argv or environment.

This contract defines the only supported shell access to the Vesta-owned
Compose control plane. It applies to an ordinary Vesta tenant using the
installed `v-docker` client and to the privileged broker that serves that
client.

## Authority and caller identity

The Unix caller is authenticated from `SUDO_UID` plus the system passwd
database. `ACTOR`, `OWNER`, and `PROFILE` are never accepted from a tenant
command line. For every tenant shell operation, actor equals owner and the
project profile equals `standard`. The broker derives the owner from the
authenticated passwd UID and passes that owner to the Vesta command; tenant
arguments cannot select another owner, actor, or profile.

Eligibility is all of the following:

- a real Unix account and a real Vesta account;
- the passwd username, UID, home directory, and login shell agree with the
  authoritative Vesta account;
- the account is neither `root` nor `admin` and is not an administrator;
- `user.conf` is the authoritative regular file, is not a symlink or hard
  link, and is not writable by the actor;
- `SUSPENDED=no`;
- the login shell is a supported interactive shell, initially `bash`;
- the effective `DOCKER_PROJECTS` entitlement is a positive integer or
  `unlimited`; and
- the current account is a member of the dedicated `vesta-compose-users`
  group.

Membership in `vesta-compose-users` is derived from active Vesta state and is
never sufficient authorization. The broker acquires the owner access lock and
then rechecks the authenticated identity, suspension state, interactive
shell, effective `DOCKER_PROJECTS`, authoritative state-file properties, and
current dedicated-group membership before every operation. Revocation and
entitlement changes therefore take effect at the broker boundary even if a
stale group membership remains in the process environment.

The owner access lock is always acquired before a project lock. No operation
may acquire those locks in the reverse order.

## Dedicated group and broker

The group grants only `v-run-user-docker-command`. It grants no Docker socket,
Docker group, Vesta state, shell, interpreter, wildcard command, or filesystem
permission. The installed privilege policy authorizes only the exact
`v-run-user-docker-command` broker; it is not a broad sudo wildcard and does
not authorize existing `v-*` Docker commands directly.

The broker is an explicit operation dispatcher. It accepts only the documented
`v-docker` operation and bounded arguments, resolves the authenticated owner,
and invokes the corresponding owner-scoped Vesta helper. It never provides a
raw Docker, raw Compose, `exec`, socket, or group-management interface.

## Tenant command catalog

The following forms are the complete tenant catalog. Accepted format arguments
are `json` and `plain`; omitted format arguments default to redacted, bounded
`json`.

The fenced TSV below is the canonical catalog. Its first column is the literal
broker operation and its second column is the complete tenant argument form.

```tsv compose-shell-catalog
projects	[json|plain]
show	PROJECT [json|plain]
definition	PROJECT [json|plain]
quota	[json|plain]
validate	PROJECT [json|plain]
health	PROJECT [json|plain]
logs	PROJECT [SERVICE] [LINES]
stats	PROJECT [PERIOD] [json|plain]
alerts	PROJECT [json|plain]
operation	PROJECT [json|plain]
routes	PROJECT [json|plain]
backups	PROJECT [json|plain]
secrets	PROJECT [json|plain]
registries	[json|plain]
registry-info	PROJECT [json|plain]
registry-publisher-change	< publisher-secret
registry-publisher-disable
image-pull	PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION IMAGE@sha256:DIGEST
drift	PROJECT [json|plain]
probe	PROJECT SERVICE [json|plain]
start	PROJECT
stop	PROJECT
restart	PROJECT
recreate	PROJECT [SERVICE]
deploy	PROJECT
preview	PROJECT add|change < compose.yaml
apply	PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
backup	PROJECT
restore	PROJECT BACKUP_ID validate|apply
rollback-preview	PROJECT REVISION
rollback-apply	PROJECT REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA
reconcile-preview	PROJECT
reconcile-apply	PROJECT DRIFT_SHA CURRENT_REVISION
secret-add	PROJECT NAME < secret-value
secret-change	PROJECT NAME < secret-value
secret-delete	PROJECT NAME
registry-add	REGISTRY USERNAME < registry-password
registry-change	REGISTRY USERNAME < registry-password
registry-delete	REGISTRY
route-add	PROJECT DOMAIN SERVICE PORT [SCHEME] [PATH]
route-delete	PROJECT DOMAIN
alert-ack	PROJECT ALERT
remove	PROJECT keep-data
```

Lifecycle operations are owner-scoped and retain the existing project data
policy. Definition changes use immutable, server-issued preview/apply state;
Compose source is read from bounded stdin, never from a tenant-selected path.
Managed backup and recovery preserve the existing retention policy. Revision
and drift mutations use server-issued evidence associated with the owner and
project. Secret and registry values are accepted only through bounded stdin or
a broker-created protected snapshot and are never command-line arguments.
Route and alert operations are limited to the owner's Vesta-owned model.
Project removal is explicit and retained-data only.

The managed Harbor operations remain owner-derived. `registry-info` accepts
only an owner-scoped standard project and an optional bounded output format;
it exposes no credential or Harbor administration. `registry-publisher-change`
accepts the publisher secret only through bounded protected stdin, never argv
or environment, and returns no secret. `registry-publisher-disable` accepts no
tenant-selected owner, endpoint, namespace, robot identity, role, API path, or
Harbor administration argument. All three operations use the authenticated
broker owner and the fixed Vesta adapters defined by the Harbor provider
contract.

`image-pull` is not a free-standing pull. The broker derives the owner, fixes
the profile to `standard`, and forwards the exact protected preview tuple plus
one immutable repository digest. The adapter verifies the unexpired
owner/project preview, current expected revision, and exactly one occurrence
of that image in protected `canonical.json` before registry inspection or
pull. It accepts no tag, URL, owner, actor, profile, platform, credential, or
Docker option argument.

There is no tenant purge form. Managed binds, named volumes, backups, routes,
and other retained data follow the Compose storage and backup contracts.

## Administrator-only exclusions

Tenants cannot select `admin-approved` or any other privileged profile. They
cannot supply a different actor or owner, impersonate another
user, access another user's project, or call the underlying `v-*` command
adapters directly. The following remain administrator-only:

- profile approval or revocation, including `v-approve-docker-project-profile`
  and `v-delete-docker-project-profile`;
- role, capability, delegated-actor, ingress-consumer mutation, and audit
  administration;
- arbitrary image pull, image load, local-image approval, trust-policy, and
  migration operations; tenant pull is limited to the exact preview-bound
  immutable form above;
- installation, group reconciliation, sudo-policy changes, and filesystem
  administration; and
- any raw Docker, raw Compose, Docker socket, host-path, namespace,
  interpreter, arbitrary command, or unrestricted archive operation.

The tenant catalog does not create a second permission path for existing
`v-*` Docker commands. Every allowed operation goes through the one exact
broker and the owner/profile checks above.

## Input, storage, and disclosure boundaries

All identifiers are validated before dispatch. `PROJECT` uses the lowercase
bounded form `[a-z0-9][a-z0-9-]{0,62}`. Service, secret, registry, backup, and
alert identifiers use `[A-Za-z0-9][A-Za-z0-9_.-]{0,62}`. Every such identifier
is at most 63 bytes. Domains are valid Vesta DNS names of at most 253 bytes, service ports
are decimal integers from 1 through 65535, and paths, schemes, periods, line
counts, revisions, digests, and preview IDs use their command-specific
allowlists and fixed maximum lengths. Empty values, control bytes, NULs,
newlines in identifiers, shell metacharacters, option injection, and malformed
hashes or revisions are rejected before any Vesta command runs.

Compose, secret, and registry input is accepted only as bounded stdin and is
snapshotted into root-owned mode-0700/mode-0600 storage. Compose input is
limited to 1 MiB per preview. A secret or registry credential is limited to
64 KiB; the snapshot is a mode-0700 directory containing mode-0600 regular
files for the duration of the broker operation. The broker never opens a
tenant-selected filesystem path as root. Restore accepts only a bounded
`BACKUP_ID`, which the server resolves as a managed backup; tenants never
provide an archive or filesystem path. Immutable preview/apply identifiers and
SHA-256 digests are exact lowercase hexadecimal values, while revisions are
`0` or a non-zero decimal integer without leading zeroes.

Preview/apply is immutable and digest/revision bound. The broker snapshots
stdin before validation, redacts managed secret material from definitions and
diagnostics, and removes temporary snapshots after completion or failure.
Secret values, registry credentials, Compose source containing managed
secrets, tenant paths, Docker environment, and raw adapter stderr never appear
in argv, process metadata, environment, stdout, JSON, HTML, logs, audit, or
unencrypted backup output. Reads expose only the contract's bounded redacted
forms.

Tenant image pull uses the owner's protected registry configuration. Lock
order is owner access, project, global tenant pull, then owner registry. Before
Docker mutation it admits exactly one Linux/approved-architecture manifest and
a positive bounded config-plus-layer size. Successful pull records protected,
owner-scoped `registry-pull` provenance bound to the preview tuple; Docker
`RepoDigests` alone is never authority. Manifest output is limited to 1 MiB,
the layer count is limited to 128, foreign descriptors are rejected, Docker
calls have fixed timeouts with raw output suppressed, and post-pull local size
must remain within the configured image limit.

The broker performs no raw Docker/Compose/`exec`/socket/group operation for a
tenant. It uses fixed root-owned Vesta command paths and bounded redacted
output. It never evaluates or sources tenant state as shell code.

## Installation, revocation, and audit

Installation is administrator-controlled. It creates or validates the
root-owned `vesta-compose-users` group, installs the single exact broker
privilege policy and client path atomically, validates the policy, and derives
membership from current eligible Vesta state. Installation is idempotent and
does not grant direct access to existing Docker commands.

Package, account, shell, suspension, quota, deletion, and administrator-state
changes must reconcile derived membership. Revocation removes the user from
the dedicated group and invalidates access at the broker's owner-lock
recheck. A stale login, stale supplementary group list, or previously issued
client token does not preserve access. Revocation never deletes retained
project data or performs a global Docker cleanup.

Audit records contain the authenticated owner, operation, project, profile,
result, bounded reason, and revision/digest identifiers where applicable.
They do not contain secrets, registry credentials, raw Compose, tenant paths,
or unredacted Docker output. Group installation, membership changes, failed
identity/entitlement checks, preview/apply, lifecycle, backup/restore,
rollback/reconcile, route, alert, secret, registry, and retained-data actions
are auditable at their respective Vesta authority boundaries.
