# Domain connection lifecycle: Vesta acceptance, 2026-09-15

The Vesta implementation of the [domain connection plan](../plans/2026-09-15-domain-connection-lifecycle.md)
is implemented and accepted within the development scope below. The integrated
API journey remains incomplete; API work from this workstation is stopped by
user instruction. This record does not authorize production promotion.

Execution history remains in issue #7, execution-ledger comment 5669043128.
Host identities, protected journals, raw release evidence, and rollback paths
remain in the private operations knowledge base.

## Accepted runtime

Development runtime: `6d68ae237bd01ccdedd40e90dabc8f68eff67f70`, succeeding
`7cf15f8d6d0f28dae95ee3847a55048cbd44650a`. The exact-file installer verified
139 source paths and three release markers, applying 12 changed source files
plus the markers. All deployed hashes, modes, and owners matched after cleanup.
Nine rollback sets were retained and their numbered backup files verified.

Managed technical allocation now stages native creation and Origin SSL with
`restart=no`, then applies validated reloads. Proxy changes and native customer
activation, certificate installation, and cleanup use the same VX helper.
Active services receive reloads; failed reloads do not trigger full restarts.
Native recovery may start an already inactive service and verifies its state.
Native activation remains synchronous when scheduled restarts are configured.

Deferred jobs use the VX adapter. Successful acknowledgement overwrites only
the matching queue line with equal-length whitespace, preserving the inode and
concurrent legacy appends. Failed work remains pending. Independent review
closed the queue-rewrite race after a regression injected an append at the
actual acknowledgement write.

## Validation

The required `test/compose/run-production-readiness-limited.sh` gate passed
with `VX_READINESS_CPU_QUOTA=100%` and no unlimited override. The unchanged
Compose graph ran while domain-specific fixes were finalized; this is not a
claim that the entire gate ran from the final immutable commit. Final domain
changes passed these focused suites:

- `test/domain-connections/test-native-configtest.sh`
- `test/domain-connections/test-native-tls.sh`
- `test/domain-connections/test-graceful-queue.sh`
- `test/cloudflare/test-cloudflare-managed-domains.sh`
- `test/cloudflare/test-cloudflare-native-lifecycle.sh`
- `test/test_web_domain_proxy.sh`

The queue suite also checks the shipped adapter's executable mode, proxy-only
jobs, unrelated entries, failed-reload retry, and acknowledgement I/O errors.
Touched Bash syntax and `git diff --check` passed. The release builder rejected
an earlier non-executable adapter before deployment; the final revision fixes
the mode and guards it in the test. Two existing files absent from the previous
overlay manifest were verified against exact prior Git bytes and metadata
before installation.

## Live evidence

Earlier native acceptance established two isolated owners, four customer CNAME
connections, trusted HTTPS with exact single-host certificates, technical URLs,
backend identity and spoof isolation, and two controlled certificate replacements.

The successor passed an additional live continuity check: a trusted customer
HTTPS download completed all 16 MiB with the expected SHA-256 while native Vesta
allocated and bound another technical domain. The technical URL served the
expected backend through public Cloudflare HTTPS. Nginx and Apache remained
active with unchanged master PIDs throughout.

Cleanup removed the extra technical domain and canary, disconnected all four
customer connections, and removed the original technical domains, fixture
owners/homes, backends, package, and eight exact customer DNS records. The
shared connection target and recovery evidence were retained. An acceptance
script initially failed when sourcing a legacy helper under `set -u`; guarded
recovery completed after confirming the already-deleted technical domain was
absent. No service outage accompanied that script failure.

Final comparison preserved all unrelated web authority and the previously
retained allocation outside this task's ownership. Four fixture authority
files disappeared as expected. Two other metadata changes were verified against
the original hashes: the administrator's user count decreased by two and a
scheduled Compose CPU sample changed from 0.1 to 0.11. All 13 container
identities, their stable runtime fields, service processes, and managed workload
authority remained unchanged. Ten containers with health checks were healthy;
one additional container was running without a health check. The panel returned
its expected unauthenticated redirect.

Enrollment remains disabled. The exact connection-worker cron and existing
native renewal scheduling remain present.

## Claim limits

A genuine registrable-apex A route, optional customer-proxy compatibility, and
future scheduled production renewal were not demonstrated live. Existing
migration and restore fixtures passed locally; live production migration and
restore acceptance remain separate. Controlled certificate replacement does
not establish a future scheduled renewal. API/UI integration acceptance and
production rollout are outside this Vesta-only completion.
