# Production host and user migration command release

## Scope and release identity

An explicitly authorized production Vesta control-plane transaction installed
commit `07207a379acaf06dbbe8308f2e9d4398604c9207`. The immutable release was
published to `origin/master` before transfer. The mutation allowlist contained
only these seven new paths:

- `bin/v-migrate-host`
- `bin/v-migrate-user`
- `func/vx/migration/archive.sh`
- `func/vx/migration/main.sh`
- `func/vx/migration/receive.sh`
- `func/vx/migration/transport.sh`
- `test/migration/test-host-user-migration.sh`

No user, site, package, route, firewall, secret, registry, Docker project, or
other workload authority was changed. No service reload or restart was
required by the installed paths.

## Release gate and artifacts

The repository-owned constrained launcher
`test/compose/run-production-readiness-limited.sh` passed unchanged before
the production connection. The deterministic archive and its reviewed inputs
were bound to:

- archive SHA-256:
  `b04480960f8391dcbc1c854e9187d45c3723ac828d45fe80cc737e0a7c7a0254`
- sorted path-list SHA-256:
  `2dcf134e29ac776bad4d59a17fa868900a2b61df15c3ba0dd93e1e870b94d74d`
- mode/hash manifest SHA-256:
  `a15dfcc6f1620ca2b405711c3b86ec236499b0687f178bde8cbe044126dd384d`

All seven paths were absent at preflight. The target was the authorized
production Vesta role on Debian 12. Its release lock was free, filesystem
capacity was sufficient, no recovery marker was present, nginx and Apache
configuration checks passed, and Vesta, nginx, Apache, and Docker were active.

## Protected transaction and rollback

The transaction held `/run/lock/vesta-vxapp-release.lock` through activation
and acceptance. It reverified the archive, path list, manifest, file types,
modes, and hashes; extracted into a root-owned mode-`0700` stage; validated
every Bash file; and installed only the allowlisted paths as `root:root` with
their Git modes.

The retained root-owned rollback is:

`/root/vesta-backups/vesta-vxapp-07207a37-production-20260817T074608Z`

Because the seven release paths were new, rollback removes precisely those
paths and restores the prior runtime identity files. The rollback contains
the accepted manifest, path list, archive hash, prior-state inventory, and
bounded acceptance evidence. It has no `RECOVERY_REQUIRED` marker.

## Production acceptance

- Every deployed file matched the immutable commit's SHA-256, mode, regular
  file type, and `root:root` ownership.
- The installed runtime marker is the full `07207a37` commit; version and
  build-date markers were updated only after file activation.
- The focused host/user migration suite passed. The host lacks `rg`, so its
  optional final reference scan emitted a missing-command warning; an
  equivalent read-only `grep` scan over all deployed migration commands and
  helpers passed with no environment-specific ecosystem reference.
- nginx and Apache configuration checks passed after activation.
- Vesta, nginx, Apache, and Docker remained active.
- Vesta user count, exact running-container inventory hash, and service restart
  counters were unchanged across the transaction.
- The panel endpoint remained reachable and returned its expected
  unauthenticated redirect.
- The release lock is free, transport and staging inputs were removed, and the
  local worktree release artifacts were removed.

This dated evidence records one authorized production release. It is not
standing authorization for another production mutation.
