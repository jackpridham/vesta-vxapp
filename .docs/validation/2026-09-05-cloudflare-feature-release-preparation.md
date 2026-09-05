# Cloudflare feature branch release preparation

## Source and integration

The repository default branch is `master`; no `main` branch exists.
`feat/issue-5-cloudflare-managed-domains` fast-forwarded local `master` from
`cd3ec72ce5166ceca8834a86a7f0d856fc8c3dde` to feature commit
`cc02f29dbff61605413b099618719e0036ca7492`, preserving all 28 feature commits.

A release review then found an external `printf` exposing the generated
phpMyAdmin administrator password in process arguments. The minimal fix and
a regression were committed as final runtime candidate
`572fa7f85a49391828b1b55662cd26ff36c569ae`. The regression fails against the
original helper and passes against the corrected helper.

The candidate includes Cloudflare managed-domain lifecycle and migration,
custom-domain form behavior, removal of panel branding, disabled password
reset, and the Vesta-owned phpMyAdmin administrator command.

## Local validation

All five focused Cloudflare suites passed, as did the phpMyAdmin and native
web proxy shell suites, Cloudflare/custom-domain/proxy PHP form suites, and
custom-domain JavaScript suite: 11 suites total.

Changed-file syntax passed for 43 Bash files, 27 PHP files/templates with
Vesta's short-tag setting enabled, and four JavaScript files. The complete
feature diff passed `git diff --check`.

The constrained production-readiness gate passed again against the corrected
runtime candidate `572fa7f8`, with default resource limits. The gate reported
one root-only disposable-container test skipped. Playwright discovery found
31 tests in 16 files; browser acceptance was executed separately on staging.

## Prepared artifacts and read-only production evidence

An external release directory contains a deterministic source archive with
86 allowlisted files and an explicit source-to-target manifest. Synthetic
tenant home directories are excluded. Two synthetic-root skeleton templates
map to the live Vesta default-template paths.

Read-only production comparison found 59 candidate files already exact in
bytes, modes and ownership; 24 files matched the prior branch baseline and
three paths were absent. No compared path had an unexpected source hash.
The proposed incremental production archive therefore contains 27 files.
Both archives were independently checked for exact path membership, regular
file types, modes and SHA-256 values.

The installed release marker remained
`07207a379acaf06dbbe8308f2e9d4398604c9207`. Vesta, nginx, Apache and Docker
were active; nginx and Apache configuration checks passed. The Compose
data-root mount guard was enabled and active, and the dedicated tenant
Compose group remained present.

Private operations guidance was consulted for compatibility revision and
image-evidence preservation, the withdrawn predecessor, the accepted
successor, retained external rollback authority and retirement gates.

## Staging acceptance

The authorized staging jump path reached a healthy host with 83 of the 86
candidate files already exact. Only the three new phpMyAdmin files were absent.
The final source was pushed to `origin/master` and a clean detached release
worktree was prepared before transfer.

A protected transaction installed those three files and the exact three
release identity files under the global release lock. It checked baseline
hashes and metadata, archive membership, staged/live syntax, service
configuration, mount-guard status, Compose group membership, and container
identity, image, health and restart evidence. Existing identity files were
snapshotted; absent payload paths were recorded for exact rollback.

The first dry run stopped before live file mutation because the release
helper's Docker template assumed every container had a healthcheck. The
helper was corrected to handle absent healthchecks, its seven isolated tests
passed, and the repeated preflight passed before installation.

Final independent verification matched all 89 payload and identity paths.
The installed phpMyAdmin regression suite passed using disposable mock state;
no live database administrator account was created. Both anonymous browser
checks passed before and after installation: expected login form/CSRF token
and absent reset link, and HTTP 404 from the password-reset endpoint.
Service/container identities and restart counts stayed unchanged. The mount
guard and Compose membership were preserved. The release lock was free,
recovery state absent, exact transfer directories removed, and protected
rollback/evidence retained outside the source tree.

## Remaining production boundary

Production remains read-only. Its proposed delta is 27 payload destinations
plus the three identity files. The two live skeleton defaults change from
mode `0755` to their reviewed `0644`; exact prior metadata is captured for
rollback. No other unexpected baseline hash or candidate metadata was found.

Explicit production authorization must identify the target, immutable runtime
release `572fa7f85a49391828b1b55662cd26ff36c569ae`, file mutation scope,
maintenance window, approval holder and continuity. The proposed transaction
does not execute phpMyAdmin account creation, configure Cloudflare, migrate
domains, change workload authority or restart services. The protected external
operator plan and transaction script define exact snapshots, newly created
paths, rollback and acceptance under the global release lock, following the
[control-plane release runbook](../user-guides/vesta-control-plane-releases.md).

This is release-preparation and staging evidence, not production deployment
acceptance or standing authorization.
