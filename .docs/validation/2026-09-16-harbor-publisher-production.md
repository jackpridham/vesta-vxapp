# Harbor publisher lifecycle repair: production acceptance

## Release and scope

The authorized production control-plane release is
`e6992339d19be694322115e32c9d3374bba83745`, immutable annotated tag
[`vesta-vxapp-20260916-e6992339`](https://github.com/jackpridham/vesta-vxapp/releases/tag/vesta-vxapp-20260916-e6992339).
It fixes issue #10 by reconciling interrupted publisher rotations during
disablement and preserving the rotation command's stderr error contract.

Production advanced from `42ed9c9c63fa4f4d0fe6f28458df2de2b3a4f9fc` through an
exact overlay of three runtime files, two isolated test files and three release
markers. The expanded dependency manifest verifies 286 source paths plus three
identities. The deployment performed no workload, quota, package, service,
registry credential, domain, DNS or scheduler mutation.

## Validation

- The resource-limited readiness launcher passed unchanged on the clean release
  commit, from `2026-09-15T23:51:39Z` to `2026-09-16T00:06:12Z`.
- It ran 62 Compose shell suites and the canonical syntax, bounded ShellCheck,
  fixture, helper/unit and documentation checks. Playwright discovered 31 tests
  in 16 files; it did not execute those browser tests. The non-root disposable
  container fixture reported its explicit skip.
- The focused publisher suite passed locally and against installed production
  sources in an isolated temporary VESTA root with mocked Harbor APIs. Seven
  isolated installer tests passed, including acceptance-failure rollback and
  failed-rollback recovery markers.
- Development had already passed two real rotate/disable cycles, ending disabled
  without remaining publisher robots or journal. Runtime pull hashes stayed
  unchanged. Production acceptance did not rotate or disable credentials.
- All 289 installed paths matched their reviewed bytes, modes and ownership.
  The locked transaction preserved 199 protected file hashes, 14 container
  observations, five service identities, mount guard and existing project
  revisions/profiles. Three existing tenant health routes returned HTTP 200.
- All 347 panel PHP/template files were readable by the actual panel worker;
  panel redirect/login checks passed. The operator separately confirmed the
  authenticated Docker/registry page loads normally.

## Closeout and limitations

The locked automated closeout completed at `2026-09-16T00:09:38Z`. Operator
confirmation arrived afterward and was recorded as supplemental acceptance
following another full-path verification under the release lock. Historical
transaction records were not rewritten.

Six exact-file rollback sets were retained, with 254 stored backup files
verified. No rollback was needed or snapshot deleted. The transfer, stage and
isolated fixtures were removed; an independent audit verified ten locks free
and no recovery residue.

A later read found two managed user files refreshed after the deployment window,
consistent with the existing scheduled RRD metrics writer; 197 other protected
file hashes matched. Whole-file equality is proved for the locked interval,
not for those later periodic metrics writes. No prior per-field snapshot is
claimed. Existing domain UI acceptance gaps are separate from this release,
which changed no panel source.

The previously observed optional-recipient-newline parsing discrepancy and
runtime credential test's timestamp-dependent assertion remain outside this
publisher repair. The current release's required gate and focused regression
passed.

Exact host identity, private manifests, authorization, rollback roots, retained
logs and operator evidence are in the operations knowledge base's SydVortex
`vesta-control-plane-e6992339-production` report. This dated record provides
validation evidence, not standing production authorization.
