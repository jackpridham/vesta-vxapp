# Deploy the Vesta Control Plane

This is the standing procedure for installing a reviewed `vesta-vxapp`
repository release on a Vesta host. It covers repository files that map to
`/usr/local/vesta`, plus explicitly included system integration files and
migrations.

This procedure does **not** deploy Vesta as a container. Vesta is installed as
host files: Bash commands and helpers, PHP, JavaScript, templates, tests,
installers, migrations, and service integration. Docker or OCI images belong
only to container workloads managed through Vesta; their separate workflow is
documented in [Docker Compose Projects](docker-compose-projects.md).

## Authorization boundary

Repository state, a successful test run, and older validation evidence do not
authorize a host mutation. Before the first connection, record outside the
release payload:

- the environment and exact target role;
- the immutable commit or signed release being installed;
- the allowed repository paths and any separately reviewed host paths;
- the permitted workload, service, package, route, secret, or migration
  mutations;
- the approval holder and maintenance window;
- the rollback or continuity plan; and
- the acceptance checks that close the release.

Development, staging, and production are separate decisions. Development or
staging success never promotes a release automatically. Production is
read-only unless the current authorization names the production target,
immutable release, workload mutation scope, approval, and rollback/continuity
scope. A deferred production adapter must return before opening a production
connection.

Use the authorized staging jump path for staging. Use only the authorized
production endpoint for production reads or an explicitly approved production
transaction. Store endpoint values in protected operator or CI configuration,
not in this repository.

## Release inputs

Prepare the release from a clean worktree whose commit is recoverable from its
configured remote. Record:

- full commit ID and, when used, immutable tag or signed-release identity;
- source archive SHA-256;
- sorted payload path list and its SHA-256;
- manifest binding every path to type, mode, owner expectation, and SHA-256;
- changed commands, helpers, templates, installers, migrations, and services;
- required preflight and post-install commands; and
- exact rollback handling for replaced and newly created paths.

Create an allowlisted archive from the immutable commit. Use a deterministic
archive umask such as `git -c tar.umask=0022 archive`; do not package the
working tree, `.git`, credentials, local environment files, runtime data,
backups, or unrelated repository paths. The live repository root maps to
`/usr/local/vesta`; for example, `bin/`, `func/`, `web/`, `install/`, and
`test/` map to the same subdirectories there.

The transport archive and checksum are temporary inputs, not deployment
authority by themselves. The reviewed manifest and authorization define the
accepted payload.

## Release validation before transfer

Run focused tests for every changed contract. Validate touched Bash with
`bash -n`, PHP with `php -l`, JavaScript with `node --check`, and render any
affected Compose fixture with `docker compose config --format json`.

Before release or deployment, run:

```text
test/compose/run-production-readiness-limited.sh
git diff --check
```

Use the limited launcher on constrained hosts. Run the canonical gate directly
only on an approved unconstrained host. Never set
`VX_READINESS_ALLOW_UNLIMITED=yes` without explicit operator approval. The
limited launcher runs the canonical gate unchanged and preserves its result.

The canonical gate checks Bash, resource-bounded ShellCheck, Compose suites and
fixtures, PHP, JavaScript, documentation consistency, Playwright discovery,
and whitespace. A failed or incomplete gate is a stop condition.

Every tracked command under `bin/v-*` must be a regular executable file with
Git mode `100755` and a shebang at byte zero. The canonical gate enforces this
before a release archive can be accepted; a deployment must preserve the
manifest mode rather than inferring executability from the filename.

## Target preflight

Before installing bytes, establish a read-only baseline under the release
lock:

1. Verify the target environment and host identity against protected operator
   configuration. Do not infer the target from DNS alone.
2. Verify the expected installed runtime marker and the exact source baseline
   for every path the release may replace.
3. Confirm required commands, package versions, filesystem capacity, mounts,
   and systemd capabilities.
4. Require relevant service configuration checks to pass before mutation.
5. Record affected Vesta package/user state, managed project revisions,
   health, restart counts, routes, runtime identities, and recovery markers.
6. Record Docker daemon identity and scoped object inventories when the release
   can affect Compose orchestration. Docker inspection is evidence, not Vesta
   authority.
7. Confirm the global release lock and every required project or owner lock can
   be acquired in the documented order.
8. Stop if unrelated recovery state, an active deployment, stale authorization,
   an unexpected baseline hash, or insufficient rollback capacity is present.

Do not “repair” a failed preflight with broad ownership changes, global Docker
cleanup, firewall mutation, or deletion of retained data.

## Protected installation transaction

Use `/run/lock/vesta-vxapp-release.lock` as the global release lock. Acquire any
owner or project locks required by the affected subsystem in its contracted
order and retain them through validation, convergence or rollback, evidence
commit, and cleanup.

Inside the locked transaction:

1. Reverify the archive, checksum, path list, manifest, immutable release
   identity, and authorization scope.
2. Create a collision-resistant, root-owned mode-`0700` rollback root outside
   the live source tree. Protected files within it are mode `0600` where
   applicable.
3. Save exact bytes, types, modes, ownership, and hashes for every existing
   target. Record separately every allowlisted path that does not yet exist.
4. Extract into a protected staging directory, never directly over the live
   tree. Reject links, unexpected types, extra paths, traversal, and manifest
   mismatches.
5. Run syntax and static checks against staged files. Validate sudoers,
   systemd units, nginx, and other service configuration before activation when
   those surfaces are included.
6. Install only allowlisted files with their reviewed root ownership and exact
   modes. Do not broadly copy or recursively change `/usr/local/vesta`.
7. Run only the named installer, migration, reconciliation, or configuration
   commands. Persist authority through Vesta interfaces; never edit user,
   package, Compose, route, registry, or secret state ad hoc.
8. Reload or restart only named services whose installed configuration requires
   it. Preserve unrelated workloads and record any authorized restart.
9. Stamp the installed runtime identity only after the live payload and required
   migrations are complete.
10. Run scoped post-install acceptance while all required locks remain held.

Any failed step triggers exact rollback. Restore prior files and metadata,
remove only transaction-created paths, reverse only explicitly rollback-safe
migrations, restore the prior runtime marker, and rerun the old-runtime
preflight. If safe automatic restoration is impossible, retain an explicit
recovery marker and stop; do not report success.

## Acceptance and closeout

Acceptance must prove, in proportion to the changed surface:

- exact live payload hashes, types, modes, and ownership;
- installed runtime/release identity;
- Bash, PHP, JavaScript, sudoers, systemd, nginx, and other affected syntax;
- required services active and configuration-valid;
- package and shell entitlements unchanged except where authorized;
- affected managed projects at the expected revision, state, health,
  freshness, restart count, image evidence, route state, and drift result;
- recovery markers absent unless the result explicitly requires recovery;
- unrelated workloads, routes, secrets, firewall state, and Docker inventories
  unchanged;
- no global prune, broad cleanup, or unapproved data deletion;
- protected audit/evidence records complete; and
- release, owner, and project locks free after closeout.

Remove the transferred archive, checksum, staging directory, temporary
credentials, and transient units after acceptance. Retain only the approved
rollback root and bounded redacted evidence for the required retention period.
Never place secret values, registry credentials, private keys, complete
environments, or customer data in release evidence.

## Production-specific requirements

A production transaction additionally requires:

- separate authorization for the exact production target and immutable
  release;
- an explicit mutation allowlist rather than a general “deploy” approval;
- exact source and state rollback material created before mutation;
- continuity treatment for every workload that may restart or reconverge;
- preservation of stopped external rollback authority and compatibility state
  unless their retirement is separately authorized;
- the repository-owned limited readiness launcher, or the canonical gate on an
  approved unconstrained host, to pass before release;
- read-only post-install acceptance through the authorized production
  endpoint; and
- a dated validation record that describes evidence without embedding private
  endpoint, tenant, application, or credential identity.

Dated validation records prove what happened during one authorized window.
They never become standing production authorization.
