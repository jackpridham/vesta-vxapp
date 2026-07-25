# Compose Lifecycle and Transaction Contract

## States

Vesta project state is one of:

`draft`, `validated`, `deploying`, `running`, `degraded`, `stopped`,
`updating`, `rolling-back`, `failed`, `removing`, `removed`, `adopted`,
`policy-stale`, or `restore-required`.

Docker state is observed evidence, not the source of ownership or desired
state.

## Operations

The system supports inspect, validate, deploy, start, stop, restart, recreate,
update, remove, and adopt. Each mutation:

- authenticates actor and owner;
- takes the project lock;
- verifies current labels and canonical digest;
- writes a start audit event without secret-bearing arguments;
- invokes `docker compose` with an explicit file, project directory, project
  name, env file, and per-owner Docker config;
- records result, duration, affected service names, and redacted stderr;
- refreshes health/counters/routes;
- releases the lock.

`stop` uses `docker compose stop`. `start` uses `docker compose start` only
when containers match the current revision, otherwise it converges with
`up -d`. `recreate` uses `up -d --force-recreate`. `remove` uses
`down --remove-orphans` and never adds `--volumes` unless the explicit purge
operation was authorized.

## Transactional deployment

1. Stage candidate definition and metadata.
2. Canonicalize and policy-check it.
3. Pull or verify every required image according to image policy.
4. Snapshot the current control-plane revision and current runtime identity.
5. Mark state `deploying` or `updating`.
6. Converge with Compose.
7. Wait for Compose/Docker health within the project timeout.
8. Validate every configured Vesta HTTP route from localhost with its Host
   header.
9. Commit the candidate revision and state only after all gates pass.

On validation, startup, health, or route failure:

- capture redacted diagnostics;
- restore the previous canonical revision;
- converge the previous revision;
- revalidate previous health and routes;
- record `rollback_succeeded` or `rollback_failed`;
- leave new-project managed data/volumes intact but remove failed
  project-owned containers/networks;
- never touch unrelated projects.

Rollback restores definitions and runtime convergence. Application-data
rollback occurs only from an explicit backup because silently rewinding
persistent data is unsafe.

## Adoption

Adoption is admin-only and supports:

- an existing Compose project whose labels and source files can be validated;
- a legacy `docker.conf` container migrated through the generated-simple
  Compose adapter.

Adoption refuses ambiguous ownership, conflicting labels/names, unmanaged
volumes, forbidden mounts, secret-like environment values, or runtime
configuration that cannot be represented by the selected profile. It has a
dry-run report and makes no changes until explicitly applied.

## Legacy migration

For each `docker.conf` record:

1. generate an equivalent one-service Compose candidate preserving image,
   command, host port, container port, managed bind roots, restart policy,
   health settings, and Vesta route metadata;
2. refuse secret-like legacy environment entries until an operator moves
   values into managed secrets;
3. validate without changing runtime;
4. on apply, preserve `docker.conf` and start-state evidence;
5. stop the legacy container, deploy the Compose project, validate health and
   route, then mark the record migrated;
6. on failure, remove only candidate Compose runtime, restart the legacy
   container, restore its route, and keep the legacy record authoritative.

Legacy records are archived, not deleted, until the final migration checkpoint
and backup/restore tests pass.
