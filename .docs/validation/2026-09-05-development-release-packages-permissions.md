# Development release and Packages template permissions

The operator subsequently reported an edit-handler failure and missing Docker
navigation. The template-only checks below did not cover the unreadable shared
include or legacy quota fields. See the
[follow-up repair and validation](2026-09-05-development-panel-package-docker-repair.md)
for the broader file-readability audit and corrective UI release.

## Authorized scope and source

The operator requested the current version on development and reported a blank
Packages page there. The installed runtime is
`572fa7f85a49391828b1b55662cd26ff36c569ae`, already accepted on staging and
production. Later `master` commits contain deployment documentation only.

The development transaction updated two phpMyAdmin helper/test files, restored
three package templates to `0644 root:root`, and installed three exact release
identity files. The templates already matched the release bytes. The remaining
84 candidate files already matched the release bytes and metadata.

The five-file incremental archive SHA-256 is
`fb2d4d1f4bd28c68d5b20688e8eae0a508ef60824871c1d30f15ff52d8d949a2`.
Its manifest SHA-256 is
`3caa40a663c2410369eff3c81d62d286cfa06fb67398b793255d3f816b479221`.

## Packages diagnosis and repair

The package list, add, and edit templates were `0600 root:root`. Vesta's PHP
workers run as `admin`, which could not read them. The suppressed template
include left the header and navigation visible but the page body empty.
The package command itself returned valid JSON with three packages.

Restoring the three templates' expected `0644` permissions fixed this rendering
failure without changing template content or package definitions. Verification
as `admin` confirmed readability and rendered the actual deployed templates
using synthetic fixtures: three list rows and both forms. The actual package
command still returned all three packages without errors.

One ordinary browser login with the protected test credentials did not
authenticate on development. Authenticated browser acceptance was therefore
unavailable; the template rendering checks did not create a persistent session
or bypass panel authentication.

## Validation and protected transaction

The exact runtime passed the constrained readiness gate and focused suites
before its earlier staging and production deployments; see the
[release preparation evidence](2026-09-05-cloudflare-feature-release-preparation.md).
This development repair required no source-code change. Seven isolated
transaction tests and an independent manifest/source review passed.

Preflight verified all 92 candidate and identity baseline paths, exact archive
membership and metadata, staged syntax, and existing services. Development's
large nginx configuration exceeded the SSH session's 1024 file limit. The
validator adopted nginx's existing 65536 service limit in its own process;
no persistent limit or service configuration changed. The development helper
also preserved the mount guard's observed absence. Production's required
guard checks remained unchanged.

The transaction held the release lock, saved exact prior bytes and metadata,
and atomically installed only its eight allowlisted targets. Independent
post-install verification passed for all 92 files: hashes, regular-file types,
expected modes, and root ownership. Staged and installed syntax checks passed.

Both anonymous browser checks passed: the login form and CSRF token were
present, and the disabled reset endpoint returned HTTP 404. The installed
phpMyAdmin regression passed against disposable mock state without changing
a live database account.

## Continuity and closeout

All 55 persisted authority-file hashes matched before and after, including
native domain state, packages and managed project authority. The four service
identities and all 13 container identities, images, start times, health,
restart counts and security settings were unchanged. Eleven containers remain
running: ten healthy with healthchecks and one exporter without a healthcheck.
The two historical stopped containers remained stopped.

Seven raw mount digests differed because Docker returned mount arrays in a
different order. Both recorded digests matched permutations of the same exact
mount records. The original inventories and this proof remain in the private
operations evidence. Group membership and the absent development mount guard
were unchanged; no service reload, restart or workload mutation occurred.

The release lock is free, no recovery marker remains, and both exact transfer
directories were removed. All eight protected inputs and 15 acceptance
evidence files remain with the rollback snapshots and acceptance record at:

`/var/backups/vesta-vxapp-releases/572fa7f8-8c6zvoah`

This records the authorized development transaction, not authorization for
future deployment or workload changes.
