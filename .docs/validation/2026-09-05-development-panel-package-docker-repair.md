# Development package editor and Docker navigation repair

## Findings and earlier coverage gap

After the first Packages template permission repair, the operator reported
that package editing still failed and a Compose user's Docker navigation was
missing. The earlier template-only rendering check did not exercise the edit
handler's shared include.

Development's `web/inc/vx_compose_package.php` was `0600 root:root`. The PHP
worker could not include it, and the edit handler then failed on an undefined
`vx_compose_package_fields()` call. Three other Git-exact PHP files were also
unreadable: `web/list/docker/index.php`, `web/ajax/docker/router.php`, and
`web/ajax/docker/actions/harbor_publisher.php`. All four corresponding files
on production were already readable with mode `0644`.

A read-only comparison covered 1,300 tracked regular files under `bin/`,
`func/`, and `web/`: 1,243 matched exactly and 57 had source or metadata
differences. A separate check as the actual `admin` worker covered all 609
audited web files and found exactly those four unreadable paths. Unrelated
local source and metadata differences were retained and recorded privately.

Package and project authority were correct. The affected user had a project
limit of two and usage of one, but five UI templates still read the legacy
container limit and usage, both zero. This hid navigation and displayed
`0 / 0` despite the managed project being running and healthy.

## Repair and immutable release

The first transaction restored only the four PHP files to `0644`, preserving
their Git-exact bytes and release identity. Its 93 candidate and three identity
checks passed; all 609 audited web files became readable by `admin`. The real
package helper loaded and normalized the package's ten quota fields.

The subsequent UI release is
`01fcf1163b5f58f4dbed87eee0841c0cf61dc07b`, recoverable from `origin/master`.
It contains five template corrections, the existing capability-rendering
regression extended to project quotas, and a test-fixture synchronization fix.
The navigation and summary regression failed before the correction and passed
afterward, including an entitled user with a zero legacy container quota.

The first full readiness attempt was stopped as incomplete when an existing
interruption fixture stalled on its FIFO reader. The fixture now waits for
the actual reader and bounds both waits, preserving the nonzero-exit and
snapshot-cleanup assertions. Focused interruption and forced-timeout cleanup
checks passed. The production broker was unchanged.

The unchanged limited launcher and canonical readiness gate then passed on
the exact final commit with a supported one-core CPU cap. Memory reserve,
task, swap and nice controls remained enabled; no unlimited override was used.
The gate reported its root-only disposable-container test skipped and
discovered 31 Playwright tests; discovery was not authenticated acceptance.

## Installation and acceptance

The protected development transaction installed seven allowlisted source
files and three identity files. One older installed test fixture was verified
against its exact historical Git version before replacement. Independent
verification passed for all 99 reviewed file/identity paths, including hashes,
types, modes and root ownership.

The installed rendering regression passed under `admin` with synthetic request
context. Actual commands through the panel's normal sudo path returned the
expected project entitlement, usage and running project. Both anonymous
browser checks passed. All 609 audited web files remained readable.

Before/after continuity records were exactly equal across 55 authority-file
hashes, four services, groups, guard state and 13 containers. Eleven containers
remained running, with ten configured healthchecks healthy and one exporter
without a healthcheck. No package, workload, route or service mutation occurred.

Authenticated package-edit and Docker-page confirmation remains unverified:
the saved credentials did not authenticate in the earlier single attempt, and
the operator was asked to refresh their existing session. Synthetic rendering,
command success and absence of new logged errors do not replace that check.

The release lock is free, recovery markers are absent, and exact transfer
directories were removed. Protected inputs and acceptance evidence remain
with the separate rollback roots:

- Permission repair: `/var/backups/vesta-vxapp-releases/572fa7f8-_r4is1ks`
- UI release: `/var/backups/vesta-vxapp-releases/01fcf116-33983x49`

Production was compared read-only and remains on its earlier release. This
record does not authorize a production promotion.
