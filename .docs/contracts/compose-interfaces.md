# Compose CLI and Web Interface Contract

## Public project commands

Commands preserve standard Vesta headers, argument checks, exit codes,
`log_history`, `log_event`, and human/JSON conventions.

```text
v-add-docker-project USER PROJECT COMPOSE_FILE [PROFILE]
v-validate-docker-project USER PROJECT [json]
v-deploy-docker-project USER PROJECT
v-start-docker-project USER PROJECT
v-stop-docker-project USER PROJECT
v-restart-docker-project USER PROJECT
v-recreate-docker-project USER PROJECT [SERVICE]
v-change-docker-project USER PROJECT COMPOSE_FILE
v-delete-docker-project USER PROJECT [keep-data]
v-adopt-docker-project USER PROJECT SOURCE [dry-run|apply]
v-list-docker-projects USER [FORMAT]
v-list-docker-project USER PROJECT [FORMAT]
v-list-docker-project-health USER PROJECT [FORMAT]
v-list-docker-project-logs USER PROJECT [SERVICE] [LINES]
v-list-docker-project-stats USER PROJECT [PERIOD] [FORMAT]
v-list-docker-project-alerts USER PROJECT [FORMAT]
v-list-docker-compose-quota USER [FORMAT]
v-acknowledge-docker-project-alert USER PROJECT ALERT
v-update-docker-project-monitoring USER PROJECT
v-backup-docker-project USER PROJECT [BACKUP]
v-add-docker-project-backup-policy USER PROJECT ENABLED SCHEDULE RETAIN_DAILY RETAIN_WEEKLY ENCRYPTION_REQUIRED REPLICATION_ADAPTER FRESHNESS_SECONDS RESTORE_TEST_INTERVAL_SECONDS
v-list-docker-project-backup-policy USER PROJECT [FORMAT]
v-run-docker-project-backup-policy USER PROJECT
v-list-docker-project-backups USER PROJECT [FORMAT]
v-restore-docker-project USER PROJECT ARCHIVE [validate|apply]
v-rollback-docker-project USER PROJECT [REVISION]
v-migrate-docker-containers USER [dry-run|apply]
v-add-docker-project-route USER PROJECT DOMAIN SERVICE PORT [SCHEME] [PATH]
v-delete-docker-project-route USER PROJECT DOMAIN
v-list-docker-project-routes USER PROJECT [FORMAT]
v-list-docker-project-ingress-consumers USER PROJECT [FORMAT] [ACTOR]
v-add-docker-project-role ACTOR USER PROJECT SUBJECT ROLE
v-delete-docker-project-role ACTOR USER PROJECT SUBJECT
v-list-docker-project-roles ACTOR USER PROJECT [FORMAT]
v-check-docker-project-capability ACTOR USER PROJECT CAPABILITY
v-compare-docker-project-revisions ACTOR USER PROJECT FROM TO [FORMAT]
v-preview-docker-project-rollback ACTOR USER PROJECT TARGET
v-apply-docker-project-rollback ACTOR USER PROJECT TARGET CURRENT FROM_MANIFEST TO_MANIFEST
v-list-docker-project-drift ACTOR USER PROJECT [FORMAT]
v-preview-docker-project-reconcile ACTOR USER PROJECT
v-reconcile-docker-project ACTOR USER PROJECT DRIFT_DIGEST CURRENT_REVISION
v-list-docker-project-operation ACTOR USER PROJECT [FORMAT]
v-run-docker-project-action ACTOR USER PROJECT ACTION [ARGUMENT] [ARGUMENT2]
v-add-docker-project-notification-route ACTOR USER PROJECT TYPE DESTINATION
v-list-docker-project-notification-routes ACTOR USER PROJECT [FORMAT]
```

The implemented delete command removes project runtime and control metadata
while retaining managed data. It accepts only `keep-data`; no public
`purge-data` path is exposed by the current command surface.

Image/registry/secret commands:

```text
v-pull-docker-image USER IMAGE
v-load-docker-image USER ARCHIVE CHECKSUM
v-add-docker-registry USER REGISTRY USERNAME PASSWORD_FILE
v-delete-docker-registry USER REGISTRY
v-list-docker-registries USER [FORMAT]
v-add-docker-secret USER PROJECT NAME VALUE_FILE
v-change-docker-secret USER PROJECT NAME VALUE_FILE
v-delete-docker-secret USER PROJECT NAME
v-list-docker-secrets USER PROJECT [FORMAT]
```

Profile/firewall/audit commands are administrator-only:

```text
v-approve-docker-project-profile USER PROJECT PROFILE EXPIRES
v-delete-docker-project-profile USER PROJECT
v-list-docker-project-audit USER PROJECT [FORMAT]
```

`v-approve-docker-project-profile` accepts installed versioned administrator
profiles, including the bridge-only `slave-vxapp` compatibility profile.
Unknown, disabled, expired, mismatched-version, or unassigned profiles fail
closed before candidate persistence.

Secret/registry values never appear in argv beyond the path of a protected
input file, stdout, JSON, or logs.

## Legacy compatibility

The existing `v-add-docker-container` and `v-change-docker-container` remain
the simple-form public interface during migration. Their implementation is a
thin adapter that generates a one-service Compose definition and invokes the
project commands. Existing list/lifecycle commands resolve Compose-backed and
archived legacy records for compatibility and audit history.

## Web panel

- The simple Add Container form remains available and generates safe Compose.
- Ordinary users may create/update only their own `standard` projects through
  an immutable preview; privileged profiles remain administrator-only.
- Users see only their projects; admins choose an explicit owner scope.
- Forms use CSRF checks and `escapeshellarg()`; AJAX actions use
  `$myvesta_logged_user`.
- Lifecycle, logs, health, resources, validation, backup, restore, revision,
  and audit views return redacted data.
- Destructive actions show whether definitions, containers, binds, volumes,
  routes, backups, and secrets are retained or removed.
- Long operations use the existing spawned AJAX process and streaming modal.
- Delegated standard-project actions use capability-specific resolution and
  actor-aware adapters; owner/admin compatibility remains intact.
- Rollback and reconcile confirmations are bound to immutable manifest or
  deterministic drift evidence and are revalidated under the project lock.
- Project/list views show typed last-operation and desired/runtime drift
  summaries; raw evidence is opt-in under Advanced JSON.

Protected web-source bridge commands are implemented for canonical preview and
spawned consumption:

```text
v-plan-docker-project-source USER PROJECT SOURCE PROFILE MODE
v-list-docker-project-definition USER PROJECT FORMAT
v-stage-docker-project-preview ACTOR OWNER PROJECT SOURCE PROFILE MODE
v-apply-docker-project-preview ACTOR OWNER PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 EXPECTED_CURRENT_REVISION
v-validate-docker-project-source USER PROJECT SOURCE PROFILE
v-web-add-docker-project USER PROJECT SOURCE PROFILE [EXPIRES]
v-web-change-docker-project USER PROJECT SOURCE
v-web-add-docker-container USER SPEC
v-web-change-docker-container USER PROJECT SPEC
```

They accept only short-lived mode-0600 files beneath an exact protected
`/tmp/vx-compose-web.<random>/` directory and remove the source after the
operation.

The plan command snapshots its regular non-symlink source once, validates a
candidate without changing desired or runtime state, and returns the redacted
deployment impact defined by
[Compose self-service deployment](compose-self-service-deployment.md).

Trusted-delivery adapters are:

```text
v-verify-docker-image-trust USER IMAGE PROFILE [FORMAT]
v-list-docker-image-update-candidate USER IMAGE [FORMAT]
```

The verifier emits the bound mode, decision, profile/policy versions, adapter
states, and exception state in JSON, or the same bounded state as a plain TSV.
The update command performs a verbose manifest inspection only; its JSON/plain
report includes the recorded registry/index digest, like-for-like current and
candidate platform digests, update availability, and `MUTATED:false`. Neither
command returns adapter stderr, attachment content, registry credentials, or
tenant paths. The full evidence and fail-closed contract is
[Compose trusted delivery](compose-trusted-delivery.md).

## JSON

JSON uses stable uppercase Vesta keys. Project responses include owner,
project, profile, desired/runtime state, revision, service summary, resource
usage, route summary, health, timestamps, and last operation. Secret values,
registry auth, raw unredacted Compose, and Docker daemon environment are never
returned.

`PUBLISHED_ENDPOINTS` is derived only from validated service-summary port
mappings. Each ordered item has `SERVICE`, `HOST_IP`, `HOST_PORT`,
`CONTAINER_PORT`, `PROTOCOL`, and `DISPLAY`. `PROJECT_ROUTES`,
`PROJECT_ROUTE_COUNT`, and `MANAGED_ROUTE_TARGETS` remain a separate
Vesta-owned routing model. Legacy simple-container fields remain available to
compatibility consumers but do not drive advanced project cards.

Health observations use observation time rather than project update time.
They report `OBSERVED_AT`, `SOURCE`, `AGE_SECONDS`, and `FRESHNESS` (`fresh`,
`stale`, or `unavailable`). Service observations add restart count, start
time, uptime, OOM state, failing streak, and bounded redacted health output.
A failed Docker observation still produces a current `unavailable` snapshot;
it does not reuse the project `UPDATED` timestamp.
