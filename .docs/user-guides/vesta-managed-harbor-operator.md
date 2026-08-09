# Install and Operate Vesta-Managed Harbor

> **Current status — procedure, not deployment authorization.** The managed
> Harbor implementation and generated credential lifecycle exist, but corrected
> development-host activation and acceptance are still pending. Production is
> deferred. Do not use this runbook to activate a production provider until a
> separate release decision names the target, release, validation evidence, and
> rollback scope. The current public installer also has no recovery-key
> initialization command, so tenant onboarding remains blocked until an
> approved release flow establishes that authority and backup validation
> passes.

This is the public administrator runbook for installing the optional
Vesta-managed Harbor provider, onboarding eligible tenants, checking its
health, creating and validating backups, and disabling access without deleting
artifacts. The normative security and state rules remain in the
[Harbor provider contract](../contracts/harbor-provider.md). Tenants publish
and deploy with the separate
[managed Harbor tenant guide](vesta-managed-harbor.md).

## How the provider fits into Vesta

The provider is infrastructure owned by Vesta, not a tenant Compose project:

```text
builder or CI
  -> Vesta hostname and panel TLS port
    -> Vesta nginx: /v2/ and /service/token only
      -> protected /run/vesta-harbor/proxy.sock
        -> Harbor project vx-<owner>

tenant v-docker preview/image-pull/apply
  -> Vesta-owned runtime pull credential
  -> immutable repository@sha256:digest
  -> managed Compose project vx-<owner>-<project>
```

Harbor stores OCI manifests, layers, and measured project usage. Vesta remains
authoritative for provider mode, tenant eligibility, namespaces, quotas,
credentials, accepted image evidence, Compose desired state, routes, rollback,
backup metadata, and audit.

The public registry origin is derived from the host's authoritative FQDN and
the existing Vesta panel TLS listener. The installer accepts no hostname, port,
version, or download URL. It does not create DNS records, request a certificate,
open a firewall port, or expose Harbor's portal, API, or metrics. Harbor has no
public host TCP listener of its own.

## Live-host layout

Repository paths map below `/usr/local/vesta` on an installed host. The main
provider locations are:

| Purpose | Live-host location |
| --- | --- |
| Vesta provider authority | `/usr/local/vesta/data/harbor/` |
| Pinned generated release | `/usr/local/vesta/data/harbor/release/current/` |
| Optional verified release cache | `/usr/local/vesta/data/harbor/release/cache/v2.15.0/` |
| Harbor database and blob data | `/var/lib/vesta-harbor/` |
| Protected proxy socket | `/run/vesta-harbor/proxy.sock` |
| systemd unit | `/etc/systemd/system/vesta-harbor.service` |
| Encrypted provider backups | `/usr/local/vesta/data/backup/harbor/` |

Do not edit generated Compose, provider JSON, owner mappings, credentials, or
nginx includes by hand. Vesta state is the source of truth. Docker inspection
and systemd state are supporting runtime evidence only.

## 1. Confirm release authorization

Before changing a host, record all of the following outside this repository:

- the approved target and whether it is development, staging, or production;
- the exact Vesta release containing the Harbor commands and pinned manifest;
- a host rollback or continuity plan that retains existing workloads;
- the acceptance transaction that will prove DNS, TLS, tenant push and pull,
  quota observation, backup validation, and access revocation; and
- explicit production authorization, if the target is production.

The dated
[development acceptance record](../validation/2026-08-08-vesta-managed-harbor-development.md)
is evidence, not standing authorization. Its current incomplete result means a
new installation must remain development-only until the missing acceptance
transaction passes.

## 2. Preflight the host

Run preflight as an administrator before `v-install-harbor-registry`.

### Vesta, Docker, and required tools

The Vesta release must already be installed at `/usr/local/vesta`. The
installer requires root and the following commands:

```bash
sudo test -x /usr/local/vesta/bin/v-install-harbor-registry
sudo test -x /usr/bin/age
sudo test -x /usr/bin/age-keygen

for command in jq python3 sha256sum tar curl cosign docker systemctl nginx openssl; do
  command -v "$command" >/dev/null || {
    printf 'missing prerequisite: %s\n' "$command" >&2
    exit 1
  }
done

sudo systemctl is-active docker.service
sudo /usr/bin/docker compose version
```

Do not work around a missing prerequisite by changing helper paths or setting
operator-selected Harbor environment overrides. Install the supported package
at its normal system path, then repeat preflight.

### Capacity

The installer rejects less than 10 GiB free on the filesystem containing the
Vesta Harbor authority root. Check that filesystem and the filesystem that
will hold Harbor data:

```bash
df -Pk /usr/local/vesta/data /var/lib
```

Ten GiB is only the enforced installation floor, not a production sizing
recommendation. Capacity planning must also cover retained image layers,
database growth, the pinned release, one previous generated release, protected
staging, and encrypted backups. Put monitoring on both filesystems. Do not use
global Docker prune or broad cleanup to make an installation pass.

### FQDN, DNS, panel listener, and certificate

The authoritative hostname must be a non-localhost FQDN, not an IP address.
It comes from `/etc/hostname`, or the platform-equivalent authoritative
hostname file. That FQDN must:

- resolve to the Vesta host from every approved builder and tenant client;
- already be reachable on the existing Vesta panel TLS port;
- be covered by the current certificate configured on the panel listener; and
- remain the same origin that tenants will receive from `registry-info`.

Use the redacted status command to exercise the same origin derivation as the
installer:

```bash
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
```

Before a first install, `MODE` may be `disabled` and `HEALTH` may be
`uninitialized`. `ORIGIN` must nevertheless be the intended HTTPS origin and
`CERTIFICATE_STATE` must be `valid`. Stop if the origin is null, names the
wrong host or port, or the certificate is unavailable. Correct Vesta hostname,
DNS, and panel TLS configuration through their normal administration paths;
do not add a separate Harbor hostname or certificate.

The installer changes only the Vesta panel nginx configuration required to
include the managed OCI routes. It does not change DNS or firewall rules.

### Pinned Harbor release

The first release is fixed to Harbor `v2.15.0`. The repository-owned manifest
pins its upstream archive, Sigstore bundle, source identity, generator image,
and every runtime image digest.

With outbound HTTPS available, the installer downloads the two pinned release
files itself. In an approved disconnected workflow, release engineering may
prepopulate exactly:

```text
/usr/local/vesta/data/harbor/release/cache/v2.15.0/release.tgz
/usr/local/vesta/data/harbor/release/cache/v2.15.0/release.sigstore.json
```

The cache directory must be root-owned mode `0700`; both files must be
root-owned mode `0600`. Cache use does not bypass checksum, offline signature
identity, archive topology, generator identity, or runtime image-digest
validation. Do not substitute another Harbor version, mirror URL, archive, or
signature bundle.

## 3. Install the provider

The installation command accepts no arguments:

```bash
sudo /usr/local/vesta/bin/v-install-harbor-registry
```

The transaction:

1. authenticates or creates the root-owned provider authority tree;
2. acquires the exclusive provider lock;
3. verifies and stages the pinned Harbor release;
4. generates a digest-pinned Compose definition without host ports or a Docker
   socket;
5. installs and starts `vesta-harbor.service`;
6. waits for PostgreSQL migration readiness, the protected socket, and Harbor
   health;
7. creates and verifies the least-privilege Vesta integration robot;
8. validates and activates the two public OCI routes in Vesta nginx; and
9. commits managed provider state and retains one previous generated release.

If any phase fails, the command returns non-zero and attempts to restore the
prior unit, ingress, provider state, service state, and generated release. It
does not mutate tenant workloads, routes, packages, or Compose desired state.
Do not repeatedly retry an unexplained failure. Inspect the bounded evidence
below, correct the prerequisite or product defect, and start a new authorized
transaction.

`v-install-harbor-registry` is also the only install/update adapter, but the
first release does not provide an automated Harbor upgrade workflow. Rerunning
it cannot select a new version and must not be presented as an upgrade.

## 4. Verify the provider before tenant onboarding

Collect provider status immediately after installation:

```bash
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
sudo systemctl is-enabled vesta-harbor.service
sudo systemctl is-active vesta-harbor.service
```

The provider is ready for an acceptance tenant only when status shows:

```text
MODE=managed
PINNED_VERSION=v2.15.0
RUNNING_VERSION=v2.15.0
HEALTH=healthy
CERTIFICATE_STATE=valid
PENDING_OPERATIONS=0
FAILED_OPERATIONS=0
```

`ORIGIN` must still match the approved Vesta FQDN and panel port. The status
command refreshes a bounded health observation when the provider is managed.
It does not print credentials, internal API responses, or a Harbor
administrator password.

For local service evidence, use:

```bash
sudo systemctl status vesta-harbor.service --no-pager
sudo journalctl -u vesta-harbor.service --since '30 minutes ago' --no-pager
sudo /usr/bin/docker compose \
  --project-name vesta-harbor \
  --file /usr/local/vesta/data/harbor/release/current/docker-compose.yml \
  ps
```

Treat diagnostic output as operational data. Do not publish complete logs,
generated configuration, Docker inspect output, or authority files in an issue
or support request. Redact hostnames, owner names, internal IDs, paths supplied
by the operator environment, and any credential-like value.

Externally, use the tenant acceptance flow below instead of exposing or
calling Harbor's private API. A missing public portal is expected: only
`/v2/` and the emitted `/service/token` route are public.

## 5. Entitle and reconcile a tenant

A tenant is eligible only when all of these are true:

- the Vesta account is not suspended;
- its effective package has positive or `unlimited` `DOCKER_PROJECTS`;
- its effective package has positive or `unlimited` `DOCKER_REGISTRY_MB`; and
- tenant self-service requirements, including interactive Bash and derived
  Compose shell access, are satisfied.

`DOCKER_REGISTRY_MB` is the provider artifact quota. The matching
`U_DOCKER_REGISTRY_MB` is a Vesta-maintained observation and must not be put in
a package or edited manually. Use the normal package workflow documented in
the [complete deployment runbook](../../DOCKER_ORCHESTRATION_DEPLOYMENT.md),
then assign the reviewed package and shell:

```bash
sudo /usr/local/vesta/bin/v-change-user-package appuser compose-standard
sudo /usr/local/vesta/bin/v-change-user-shell appuser bash
sudo /usr/local/vesta/bin/v-sync-harbor-registry-owner appuser
```

The package must be a complete Vesta package; do not create it from only the
two Docker fields above. Normal package application journals the desired
registry quota and reconciles forward. The explicit sync is a safe repair or
acceptance step, not a substitute for package authority.

Review redacted owner state:

```bash
sudo /usr/local/vesta/bin/v-list-harbor-registry-owners json \
  | jq '.[] | select(.OWNER == "appuser")'
```

Initial reconciliation creates or validates one private Harbor namespace,
sets its quota, and creates a distinct Vesta-owned runtime pull credential.
It does not create a publisher credential until the tenant performs an
encrypted publisher rotation. Expected initial owner state is
`runtime-ready`, with `PUBLISHER_ENABLED=false`.

To reconcile all current owners and replay retained deletion tombstones:

```bash
sudo /usr/local/vesta/bin/v-sync-harbor-registry-owners
```

The systemd service also starts an all-owner reconciliation after provider
startup. A non-zero result or a pending/failed operation is a stop condition;
do not bypass it by editing owner JSON or creating projects in Harbor.

## 6. Run the first-tenant acceptance transaction

Use a dedicated development acceptance tenant and a disposable application
image. `registry-info` does not create a Compose project: the owner-scoped
`standard` project must already exist through the approved external-image or
administrator bootstrap described in the tenant guide. From the tenant
account, request discovery for that project name:

```bash
ssh registry.example.net \
  v-docker registry-info myapp json | jq .
```

Require all of the following before generating a publisher credential:

```text
MANAGED=true
STATE=ready
HEALTH=healthy
FRESHNESS=fresh
REGISTRY=<approved Vesta FQDN:panel-port>
REPOSITORY=<REGISTRY>/<owner namespace>/myapp
QUOTA_MB=<assigned package quota>
```

Then follow the canonical
[tenant publishing workflow](vesta-managed-harbor.md#canonical-release-workflow-after-activation)
without changing it:

1. create a temporary native X25519 age identity on the builder;
2. rotate the publisher through bounded `v-docker` stdin and capture only the
   armored ciphertext;
3. decrypt directly into `docker login --password-stdin` using a protected
   Docker credential store;
4. build, test, push a versioned tag, and resolve its immutable digest;
5. preview Compose through stdin, perform the preview-bound digest pull, apply
   the unchanged preview tuple, and verify the workload;
6. confirm `USED_MB` is observed and quota enforcement remains effective; and
7. disable the publisher and confirm runtime pulls and the accepted workload
   continue while new pushes fail.

Acceptance is incomplete unless the encrypted provider backup and
validation-only restore in the next section also pass. A successful image push
alone proves neither deployment nor recoverability.

## 7. Back up and validate recovery

Provider backup is separate from every tenant Compose backup. It briefly stops
only a provider that was running, snapshots the allowlisted authority,
configuration, database and blob state, encrypts recovery secrets separately,
encrypts the outer archive with age, and restarts only that provider.

The backup implementation requires an approved provider recovery identity and
matching recipient before the first backup. The current public command catalog
has no manual recovery-key initialization command, and
`v-install-harbor-registry` accepts no recovery-key arguments. Therefore the
release acceptance process must establish and verify this authority; operators
must not invent it or write these files by hand. Verify only ownership and
mode, never contents:

```bash
sudo stat -c '%U:%G %a %h %n' \
  /usr/local/vesta/data/harbor/backup-recipient.txt \
  /usr/local/vesta/data/harbor/secrets/backup.agekey
```

Both must be regular, single-link, root-owned mode-`0600` files. If either is
absent or invalid, `v-backup-harbor-registry` fails closed. That is a release
blocker: stop before onboarding tenants and correct the installation/release
workflow rather than generating authority ad hoc.

Create a backup and retain its non-secret ID:

```bash
backup_id="$(sudo /usr/local/vesta/bin/v-backup-harbor-registry)"
printf '%s\n' "$backup_id"
sudo /usr/local/vesta/bin/v-restore-harbor-registry "$backup_id" validate
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
```

Validation must print `validated`, leave the running provider unchanged, and
status must report a non-null `BACKUP_AGE_SECONDS`. The ciphertext is stored
under `/usr/local/vesta/data/backup/harbor/`; its root-owned metadata remains
under provider authority. Copy ciphertext and the required recovery custody
material into the approved off-host system-backup process without printing,
emailing, or committing either.

First-release restore is validation-only:

```bash
sudo /usr/local/vesta/bin/v-restore-harbor-registry "$backup_id" apply
```

The command above must refuse with exit status `78`; it is shown to make the
boundary explicit, not as an action to perform during routine validation.
There is no supported automatic restore apply. Disaster recovery requires an
authorized operator procedure on an isolated host with the same pinned
version, protected staging, sufficient capacity, manifest and ownership
verification, private authenticated health checks, mapping reconciliation,
and transactional ingress activation. Take a new encrypted backup before
replacing any existing provider.

## 8. Routine operation

Use JSON status for automation and alert on any unexpected mode, health,
certificate, operation, storage, or backup result:

```bash
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
sudo /usr/local/vesta/bin/v-list-harbor-registry-owners json | jq .
```

The provider status contains:

- `MODE`, pinned/running versions, origin, and certificate state;
- bounded provider health and storage totals;
- pending and failed package/owner operations; and
- age of the last successful encrypted backup.

Owner status contains only owner, namespace, lifecycle state, quota, publisher
enabled state, and update time. Tenant `registry-info` adds the repository for
the requested project plus fresh measured usage. None of these interfaces
returns passwords or internal Harbor administration data.

Operational responses are fail-closed:

| Observation | Operator response |
| --- | --- |
| `HEALTH` is not `healthy` | Stop new publishing and deployment; inspect service, socket, storage, and bounded logs. Existing workloads should remain unchanged. |
| Certificate is invalid or origin is wrong | Correct authoritative Vesta hostname/TLS configuration. Do not bypass validation or add a second registry endpoint. |
| Pending owner operation | Restore provider availability, then repeat the same owner sync so its operation ID can resume. |
| Failed owner operation | Inspect the redacted error and desired package state. Do not publish a conflicting package change. |
| Tenant freshness is stale/unavailable | Refresh administrator status and reconcile the owner; do not rotate, push, pull, or apply until fresh. |
| Storage is near capacity | Stop growth and expand approved storage. Do not delete arbitrary blobs or run global prune. |
| Backup is missing or too old | Stop activation/release work, create and validate a provider backup, then resume. |

Package reduction below fresh observed registry usage is rejected. Setting
`DOCKER_REGISTRY_MB=0`, suspending/deleting a user, or otherwise removing
eligibility revokes publishing and runtime registry access while retaining the
private Harbor project and artifacts. It does not delete Compose projects or
running workloads.

## 9. Disable the provider without deleting data

Disable is a two-step, short-lived confirmation flow. Capture and review one
complete plan in a controlled root session:

```bash
disable_plan="$(
  sudo /usr/local/vesta/bin/v-plan-disable-harbor-registry json
)"
jq . <<<"$disable_plan"
```

Do not continue when `BLOCKERS` is non-empty. Review every affected owner and
the retained-data list. Resolve package operations and generate a new plan;
do not edit the token or plan file.

The plan token expires after five minutes and is bound to the exact current
owner and operation sets. If that captured plan has no blockers and is still
current, pass only its token:

```bash
test "$(jq -r '.BLOCKERS | length' <<<"$disable_plan")" -eq 0
disable_token="$(jq -er '.TOKEN' <<<"$disable_plan")"
sudo /usr/local/vesta/bin/v-disable-harbor-registry "$disable_token"
unset disable_token disable_plan
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
```

Disable revokes publisher credentials first, then runtime credentials,
removes managed public ingress, stops the provider, and sets `MODE=disabled`.
It retains the Harbor database, OCI artifacts, owner mappings, generated
release, and encrypted backups. It does not change tenant Compose desired
state, containers, routes, volumes, binds, DNS, firewall, or packages. There
is no provider purge command in the first release.

## 10. Troubleshooting installation failures

Use the last completed phase and these checks to narrow the failure:

| Failure area | Check |
| --- | --- |
| `prerequisite` | Root execution, exact tools, Docker/Compose, and at least 10 GiB free on the authority filesystem. |
| `release` | Outbound HTTPS or the exact protected cache files; pinned hashes, Sigstore bundle, source identity, and archive topology. |
| `generation` | Pinned generator image identity, `/var/lib/vesta-harbor` type/ownership, and no unsupported local changes. |
| `compose` or `migration` | `docker.service`, systemd status, digest-pinned containers, and bounded PostgreSQL readiness. |
| `socket` or `health` | `/run/vesta-harbor` ownership/mode, container health, storage, and the Unix socket; never expose a diagnostic TCP port. |
| `integration` | Preserve rollback and report a product defect with redacted evidence; do not use the bootstrap administrator for routine operation. |
| `ingress` | Vesta nginx syntax, its single panel listener, worker group, FQDN, and certificate. Do not add Harbor API or portal routes. |

After any failure, verify the resulting state before another attempt:

```bash
sudo /usr/local/vesta/bin/v-list-harbor-registry json | jq .
sudo systemctl is-active vesta-harbor.service || true
sudo systemctl status vesta-harbor.service --no-pager || true
sudo journalctl -u vesta-harbor.service --since '30 minutes ago' --no-pager
```

A failed fresh transaction should leave the provider disabled and restore
prior ingress and service state. If rollback reports cleanup pending, stop and
escalate with the exact release identity, failed phase, redacted status, and
retained rollback evidence. Do not delete `/usr/local/vesta/data/harbor`,
`/var/lib/vesta-harbor`, Docker objects, or backups to force a retry.

## Related documentation

- [Managed Harbor tenant deployment guide](vesta-managed-harbor.md)
- [Harbor provider contract](../contracts/harbor-provider.md)
- [Complete source-to-Vesta deployment runbook](../../DOCKER_ORCHESTRATION_DEPLOYMENT.md)
- [Container-orchestration architecture and operator guide](../../docs/container-orchestration.md)
- [Development acceptance evidence](../validation/2026-08-08-vesta-managed-harbor-development.md)
