# Cloudflare feature production control-plane release

## Authorization and immutable source

After reviewing the prepared scope and successful staging acceptance, the
operator explicitly approved the production deployment. Installed runtime:
`572fa7f85a49391828b1b55662cd26ff36c569ae`, recoverable from `origin/master`.

The mutation allowlist contained exactly 27 payload files and three release
identity files. It installed the phpMyAdmin administrator command/helper/test,
updated panel branding and disabled password reset, and updated shipped
skeleton defaults. Two live skeleton files changed from mode `0755` to their
reviewed `0644`; their original metadata was captured for rollback.

No provider configuration, domain migration, live database-account creation,
package, route, secret, firewall or workload mutation was performed. No service
reload or restart was performed.

## Release gate and preflight

The constrained production-readiness gate passed against the exact runtime
candidate before staging and production transfer. The focused suites and
staging results are recorded in the
[release preparation evidence](2026-09-05-cloudflare-feature-release-preparation.md).
The gate reported one root-only disposable-container test skipped; separate
browser acceptance ran on both staging and production.

Production's freshly checked 89-path baseline matched the reviewed inventory:
59 payload paths already matched the candidate, 24 matched the prior baseline,
three were absent, and three existing release markers matched their snapshots.
The installed marker before the transaction was
`07207a379acaf06dbbe8308f2e9d4398604c9207`.

The deterministic incremental archive SHA-256 was
`c3a426d8d175bf0e7b5427b5fc826e9675ef42046c9056ab6b4c39db7ad0be66`.
The exact payload manifest SHA-256 was
`7f4dc6d6c327571e22899139addaf194bc6ea1c0053296699b1a2ab0661246d6`.
The identity manifest SHA-256 was
`c47dfea7f243f9308718fdad897309a93d1ff4138fcc2e562844ccda6815711d`.

Protected transfer checksums, archive membership, file types/modes, baseline
hashes, staged syntax and live service/configuration checks passed before
installation. Private operations guidance and read-only continuity evidence
were checked before applying the release.

## Protected transaction and acceptance

The transaction held `/run/lock/vesta-vxapp-release.lock` through snapshots,
installation, syntax/configuration checks, service/container comparison and
acceptance. It rejected untrusted paths and unsupported metadata, retained
exact old bytes and metadata, recorded absent paths, and atomically installed
only the approved files. All 86 payload paths were verified before stamping
the three exact identity files.

Independent post-install verification passed for all 89 payload and identity
paths: SHA-256, regular file type, exact mode and `root:root` ownership.
Vesta, nginx, Apache and Docker remained active with unchanged runtime
identities and restart counts. nginx and Apache configuration checks passed.

Both anonymous production browser checks passed: the expected login form and
CSRF token were present with no reset link, and the reset endpoint returned
HTTP 404. The installed phpMyAdmin regression passed against disposable mock
state; it did not create or rotate a live database administrator account.

Independent before/after continuity records matched exactly across 54 persisted
authority files, including native web domains, packages, project revisions,
image evidence, policy, routes and canonical definitions. Group membership,
the enabled/active mount guard and its unit hash, and the stopped external
rollback container and original volumes were unchanged. No owner Docker-group
access or project recovery state was present.

## Closeout and rollback retention

The release lock is free and the recovery marker is absent. The exact protected
transfer directory was removed. Reviewed manifests, authorization, transaction
snapshots and continuity evidence remain with the protected rollback root:

`/var/backups/vesta-vxapp-releases/572fa7f8-tmmd7qln`

Rollback restores the exact replaced files and prior identity, and removes
only the transaction-created allowlisted paths. Existing external workload
rollback authority remains separately retained; this deployment does not
authorize its retirement.

This records one approved production transaction, not standing authorization
for future changes.
