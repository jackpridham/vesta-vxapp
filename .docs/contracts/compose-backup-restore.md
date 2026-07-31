# Compose Backup and Restore Contract

## Backup contents

A project backup includes:

- canonical Compose and non-secret variables;
- project/profile/policy metadata;
- route metadata;
- audit history for the project;
- revision manifests needed for rollback;
- managed bind data selected by policy;
- managed named-volume data captured from a fixed, reviewed helper image;
- image identity manifest, not image layers;
- secret-name manifest;
- optionally, a separately encrypted secret payload under the secrets
  contract.

It excludes registry credentials, Docker daemon state, container writable
layers, build cache, raw image archives, sockets, devices, and unrelated
projects.

## Consistency

Backup takes the project lock. The default application-consistent sequence is:

1. record runtime state;
2. run an approved per-profile pre-backup hook if present;
3. stop services when the profile requires cold backup;
4. archive definitions/data with numeric ownership and path checks;
5. calculate a manifest of SHA-256 hashes;
6. restart only services that were running;
7. verify health/routes;
8. record the backup result.

No broad Docker volume traversal or prune is permitted.

## Restore

Restore always targets an explicit owner/project and supports validation-only.
It:

- rejects traversal, absolute archive members, links escaping the restore root,
  devices, FIFOs, and unexpected files;
- verifies every manifest hash before mutation;
- canonicalizes/policy-checks Compose under current policy;
- verifies image availability by digest;
- restores into a staging root;
- checks package quotas before installing data;
- installs definitions/data atomically;
- restores secrets only through the encrypted-secret workflow;
- deploys and validates health/routes;
- rolls back to the pre-restore revision/data snapshot on failure.

Cross-user restore requires admin authorization and rewrites stable project
identity/labels only after full validation.

## Retention and destructive behavior

Backups are ordinary Vesta backup artifacts and participate in existing
retention. Removing a project never removes its last known-good backup.
The current public project remove command retains data. Any future
volume/data purge must be a separate audited operation with an explicit
confirmation token and backup-state checks.

## Managed backup policy

Each configured project persists a root-owned, mode-`0600`
`backup-policy.conf` below its control root. Schedules use either
`daily@HH:MM` or `weekly@dow@HH:MM` in UTC. Retention accepts no fewer than
seven daily and four ISO-week recovery points and always retains the last
known-good archive. Policy runs hold the existing project lock through backup,
validation-only restore, retention, replication, audit, and atomic state
update.

Cold backup writes a mode-`0600`, owner/project-bound recovery marker before
stopping a running workload. Normal signal handling redeploys that exact
workload and removes only scoped staging. A later locked invocation recovers a
marker left by an untrappable interruption before new work; recovery failure
retains the marker and sets `restore-required`. `LAST_ATTEMPT` plus
`LAST_ERROR=run-in-progress` is the durable operation marker. Terminal fields
are validated and replaced together as one exact 17-field file; retention
completes before a successful terminal state or success audit is recorded.

The daily host job enumerates only regular mode-`0600` policy files, takes one
host scheduler lock, and invokes due owner/project pairs directly. It never
writes project values into cron. Replication adapters are named executables
below `func/vx/compose/replication-adapters/`; they receive the protected
archive on file descriptor 3 and return only `STATE` and an optional redacted
`REFERENCE`. Missing external target or key configuration is
`not-configured`, never success. `local-fixture` exists solely for disposable
staging validation and requires a root-owned mode-`0600`
`conf/vx-compose-replication-local-fixture.conf` naming an existing,
root-owned mode-`0700` `TARGET_ROOT`. It copies and verifies the descriptor
before reporting success. When encryption is required, the descriptor is a
temporary whole-archive age ciphertext, never the managed plaintext archive;
the temporary payload is mode `0600` and removed after the adapter returns.
Adapters execute with an empty environment containing only the controlled
safe `PATH` and `VESTA`; their only other inputs are validated owner/project
arguments and descriptor 3.

Validation-only restore drills extract into a disposable root, verify archive
structure and checksums, and remove that root without mutating desired state,
runtime, binds, volumes, routes, or secrets. Backup alerts use the typed values
`missed-run`, `backup-failure`, `freshness-breach`,
`encryption-unavailable`, `replication-lag`, `replication-failure`, and
`restore-test-failure`; best-effort notification failure never changes the
backup or lifecycle result.

The policy file is included in project archives and its exact field schema,
values, timestamps, states, and archive name are validated during restore
preparation. Apply restores only its reviewed configuration
(`ENABLED`, schedule, retention, encryption, adapter, freshness, and drill
interval), recomputes `NEXT_RUN`, and resets every attempt/result timestamp,
error, archive, replication, and drill state. The policy switch is atomic; an
existing target policy is snapshotted inside the core restore transaction and
restored by its normal rollback path if a late switch fails. New-project
restore installs the same sanitized candidate before success and removes it
with the new control root on failure. Validation-only restore never changes
policy authority.

## Acceptance

Integration tests prove definition, bind, named-volume, route, audit, secret
manifest/encrypted secret, stopped/running state, checksum failure, malicious
archive, quota failure, and failed-health rollback behavior.
