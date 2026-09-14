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
An authenticated browser session was unavailable to the agent during
installation; worker rendering was verified separately. During the follow-up
audit the operator confirmed, from their existing authenticated session, that
Users, Packages, Edit User and Docker navigation render correctly with project
quotas. This is operator confirmation, not an automated authenticated test.

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

## Follow-up deployment audit

The deployment-maintenance skill was audited after installation. A fresh
read-only check held the release, owner and project locks and verified all
97 live files, all ten protected rollback snapshots, the 54 unchanged authority
hashes, installed orchestration readiness, mounts, services and workloads.
The bundled-PHP worker regression reached an explicit completion sentinel.
The backend and all three native proxy health endpoints returned HTTP 200.

The annotated release tag `vesta-vxapp-20260914-2e0a3b3b` was published during
this audit and peels to the installed commit. Before installation the exact
commit was remotely recoverable, but the branch was unprotected and no release
tag had been created. The exact source archive was reproduced from Git, and
the path list, input checksums and retained evidence inventory were checked.

The operations guidance incorrectly described current compatibility revision 5
as five-field legacy image evidence. Its actual schema-2 files match the
September 5 predeployment hashes; neither this release nor the audit migrated
them. The guidance now distinguishes current evidence from the historical
legacy compatibility boundary without changing that boundary's validator.

Historical process gaps are retained in the private audit record: exact gate
start/end timestamps and contemporaneous tool versions were not captured;
the authorization file followed the first read-only connection; transfer
preparation preceded the release lock; and the independent browser checks and
final transfer cleanup used later phases rather than one uninterrupted lock.
Current verification closes the evidence gaps but does not retroactively
change that sequence. The skill now makes these requirements explicit for
future releases. No production runtime or workload change was needed.
