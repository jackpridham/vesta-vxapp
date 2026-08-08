# Vesta-Managed Harbor Development Acceptance — 2026-08-08

## Outcome

**BLOCKED.** Development acceptance stopped before Harbor activation because
the authorized host's existing Vesta TLS identity is not valid for its
authoritative hostname. Production deployment is deferred. No production host
was contacted.

## Release identity and authorization boundary

- Authorized path: `gizmo@192.168.100.16` to
  `debian@192.168.100.100` only.
- Development host identity: `sydlocal.jackpridham.com`, Debian 13 kernel
  `6.12.57+deb13-amd64`.
- Initial candidate: `004fdcf7`.
- Product fix after local acceptance: `dc48f21e`.
- Exact staged commit after live adapter correction:
  `0f5849a5d2a8344a65c9756d541fdc4553d75b2a`.
- Runtime marker/version: `0f5849a5...` /
  `0.9.9-0-16+vxapp.0f5849a5`.
- No connection to `syd.vortexenterprises.com.au` was made. No firewall, DNS,
  NAT, public route, tenant route, or production change was attempted.

## Local Milestone 5 run

The required command was invoked once:

```text
bash test/harbor/run-focused.sh
exit=1
Harbor fixture tests passed.
Harbor provider state tests passed.
PASS: Harbor redacted status and endpoint guards
```

The next declared suite, `test-package-quota.sh`, rejected recovery of a
correctly persisted `pending/provider-unavailable` operation because the exact
authority schema incorrectly required every pending operation to have a null
diagnostic. Commit `dc48f21e` removed that contradictory rule. The affected
suite then passed, along with Bash syntax, Python compilation, and
`git diff --check`.

During diagnosis the aggregate was mistakenly started a second time under
`bash -x`. It repeated the first three suites and entered the same failing
package-quota suite before being terminated; it did not proceed beyond that
suite. The aggregate was not run again after the fix. This deviation is
retained explicitly and prevents claiming the requested clean once-run result.

Live invocation then exposed ten Harbor public adapters that did not initialize
`VESTA` when called without an exported environment. Commit `0f5849a5` added
the standard `/usr/local/vesta` default. The affected `test-status.sh`, Bash
syntax, and whitespace checks passed.

## Development preflight

Preflight captured the following redacted facts before Harbor installation:

- `/usr/local/vesta`: `root:root`, mode `0755`; prior marker `276eb9f6...`.
- Root filesystem: 153 GiB total, 109 GiB free.
- Docker `26.1.5+dfsg1`; Compose `2.26.1-4`.
- Vesta, nginx, Docker, and Apache were active.
- Harbor service, provider root, data root, ingress include, unit, and Unix
  socket were absent.
- Existing panel listener: `0.0.0.0:8083`; no Harbor host TCP listener.
- Existing managed workload: container `fa36ad4cc920`,
  `vx-asteriskvx-pbx-asterisk-1`, healthy. Its ID and running state remained
  unchanged through staging and both failed install attempts.
- Existing owners were inventoried. No existing project was selected for
  acceptance and `slave/slave-vxapp` was not mutated.
- Debian's signed repository supplied the missing prerequisite
  `cosign 2.5.0-2+b4`. Package installation reported that no containers needed
  restart. It refreshed host services but did not restart the tenant container.

## Transactional staging and rollback

The exact `dc48f21e` runtime payload archive had SHA-256
`fa35d7bf5c2be1acf3d16190bdbaef79e98632fd6b9c4541552d03a0404eacdf`.
Transfer and remote hashes matched. An initial staging attempt stopped before
backup or installation because its harness applied Bash syntax checking to a
legacy PHP `v-*` command. Only the exact empty attempt directories were
removed. The corrected transaction:

- held `/run/lock/vesta-vxapp-release.lock`;
- captured every overwritten file and every absent path;
- captured runtime markers, listeners, and managed-container inventory;
- checked staged Bash and PHP syntax;
- installed root-owned repository bytes without deleting unrelated files;
- verified each installed file byte-for-byte; and
- installed only the required Debian `cosign` package.

The adapter-only successor archive SHA-256 was
`0b129775060f5c907b3a00e720fda2fa08f69e7513e8f323cf3c129a6d3da1b8`.
It was hash-verified and installed under the same release lock. The retained
root-owned mode-0700 rollback is:

```text
/root/vesta-backups/vesta-harbor-task10-dc48f21e
```

It contains prior files, an absent-path list, original runtime markers,
listener/container baselines, and restoration instructions. Harbor's provider
data retention policy remains separate.

## Install attempts and exact blocker

Attempt 1 used `v-install-harbor-registry`. It failed transactionally and
restored the prior service, ingress, and provider state. Attempt 2 added only a
redacted phase callback. It passed `prerequisite` and `release`, proving the
official Harbor v2.15.0 archive digest and offline signature bundle were
accepted, then failed before the `generation` phase.

Direct isolation showed `vx_harbor_origin_json` fails because:

```text
authoritative hostname: sydlocal.jackpridham.com
Vesta certificate CN/SAN: syd.vortexenterprises.com.au
certificate validity: 2025-11-24 through 2026-02-22
acceptance date: 2026-08-08
```

The certificate is both expired and invalid for the development hostname.
The install therefore fails closed before generating configuration or starting
Harbor. Repair requires a correctly named, currently valid certificate (and
potentially DNS/ACME authority), which cannot be safely created without the
explicitly prohibited DNS/route/certificate expansion. Hostname or certificate
validation was not weakened.

After each failure:

- provider state was exact disabled state with pinned version `v2.15.0`;
- `/var/lib/vesta-harbor`, the systemd unit, ingress include, and Unix socket
  were absent;
- `vesta-harbor` was not found/inactive;
- no Harbor container or Harbor TCP listener existed; and
- container `fa36ad4cc920` remained healthy with the same ID.

## Acceptance not claimed

Because activation could not safely pass the existing-TLS prerequisite, no
operation IDs, owner namespace/quota, runtime/publisher robots, secret-boundary
push, immutable image digest, tenant preview/apply revision, health/drift,
revocation/outage, encrypted backup validation, or managed disable plan was
created. No disposable acceptance owner/project was created. These Task 10
checks remain blocked rather than being simulated or weakened.

Task 11 independent reviews, the limited production-readiness launcher, push,
and production deployment were not performed. **Production deployment:
deferred.**
