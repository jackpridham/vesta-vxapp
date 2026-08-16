# Production Vesta command-mode repair

## Scope and release identity

Production installed the runtime portion of commit
`11f7fd329298ca99b71c9eab4b1bdf32fc228309`. The transaction changed only
the 91 tracked `bin/v-*` paths whose Git mode was `100644`, corrected two
displaced shebangs among those paths, reloaded nginx, and stamped the runtime
release identity. It did not change Vesta user, package, route, Docker,
firewall, secret, or workload authority.

## Root cause

Upstream merge `83104523a0813cc5ba1b516bcaeeb891c5b26f82` changed
`bin/v-restart-proxy` from mode `100755` to `100644` on 2020-08-19. The
following content revert retained the incorrect mode. Later command additions
also accumulated with mode `100644`, producing 91 non-executable Vesta command
files in the source tree.

The host-file deployment on 2026-08-08 preserved the repository modes. It did
not independently corrupt the files, but the release gate had no invariant
covering the complete `bin/v-*` surface and therefore accepted the bad source
metadata. A web-domain ownership change later exposed the defect when
`v-rebuild-web-domains` attempted to execute `v-restart-proxy`.

## Permanent correction

- All tracked `bin/v-*` commands now have Git mode `100755`.
- The two commands whose shebangs had a leading space now have a byte-zero
  shebang.
- `test/compose/test-command-modes.sh` rejects non-regular, non-executable,
  incorrectly tracked, or displaced-shebang Vesta commands.
- The production release guide now requires the mode and shebang invariant and
  exact manifest preservation.

## Validation and production acceptance

- All 90 affected Bash commands passed `bash -n`; the affected PHP command
  passed `php -l`.
- The focused command-mode and documentation checks passed.
- `test/compose/run-production-readiness-limited.sh` passed unchanged,
  including the new command-mode test.
- The production preflight matched all 91 prior bytes, modes, and owners to the
  parent commit before mutation.
- All installed Vesta commands are now executable and have byte-zero shebangs.
- Direct execution of `v-restart-proxy` succeeds with the fixed Vesta
  environment, and its background nginx restart completed.
- nginx and Apache configuration checks passed; Vesta, nginx, and Apache are
  active; the panel and affected public proxy endpoints returned HTTP 200.
- Both managed production workloads remained running and healthy with zero
  restarts.
- The release lock is free, transport staging was removed, and the protected
  rollback root is
  `/root/vesta-backups/vesta-command-modes-production-20260816T061305Z-11f7fd329298`.

The first checksum preflight and first rollback-snapshot attempt both stopped
before activation. The first post-install restart invocation lacked the Vesta
environment and made no effective reload; the corrected invocation completed
before acceptance.
