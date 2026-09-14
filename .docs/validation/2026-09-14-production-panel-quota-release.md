# Production panel quota release

Production accepted immutable source
`2e0a3b3bfcd5c9fca1d2f27b54dc217c09f4b9dc` following the operator's explicit
deployment request. This was the remotely verified `master` tip at release
preparation. The installed version is `0.9.9-0-16+vxapp.2e0a3b3b`.

## Scope and baseline

The transaction installed five panel templates, two test fixtures and three
release identity files. Docker navigation and quota summaries now use
`DOCKER_PROJECTS` and `U_DOCKER_PROJECTS`. The existing domain-alias hotfix
already matched the candidate and was retained.

The prior runtime was the accepted `572fa7f8` base plus the `48e020eb`
one-file overlay. Six payload files matched the base; the namespace test
fixture matched exact historical source `bd901e03`. All seven replacements
had expected ownership and modes. No migration or service restart was needed.

## Validation and transaction

The repository's limited production-readiness launcher passed on the exact
release with its default resource controls. The root-only disposable-container
test was skipped; all runnable stages passed, including discovery of 31
Playwright tests. Seven existing installer transaction tests passed.

The protected transaction verified the archive, immutable manifest, machine
identity, exact baseline, capacity, service configuration and recovery state.
It held the release lock through snapshots, atomic installation, acceptance
and stage cleanup, with exact-file rollback armed.

Independent verification passed for all 94 candidate files and three release
markers: regular file types, SHA-256, modes and root ownership. Syntax passed
with both system PHP and the panel's bundled PHP 5.6 runtime. The installed
capability/navigation/quota regression passed as the PHP worker account with
synthetic request context and no warnings. All 346 PHP/template files in the
audited web tree were readable by that account.

Both anonymous browser checks passed before and after installation. The panel
root returned HTTP 302, login returned 200 and password reset returned 404.
An authenticated browser session was unavailable, so full authenticated page
acceptance remains unconfirmed; worker rendering was verified separately.

## Continuity and closeout

The locked before/after records matched exactly across 54 protected authority
file hashes, service and container identities, health/restart observations,
access groups, the enabled/active mount guard and retained external rollback
container/volumes. Compatibility and PBX project profiles/revisions remained
unchanged. No workload, route, package, provider, secret or firewall mutation
or service reload/restart occurred.

The exact transfer directory was removed, the release lock is free and no
release recovery marker remains. Protected snapshots, manifests, readiness
evidence and acceptance records are retained at:

`/var/backups/vesta-vxapp-releases/2e0a3b3b-5v3shp98`

This records one authorized production deployment and does not authorize
future production changes.
