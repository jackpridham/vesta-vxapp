# Compose Shell Access Development Validation — 2026-08-07

## Scope

Milestone 3 local implementation and disposable validation for derived group
membership, exact broker-only sudo installation, and tenant shell revocation.

## Development-host acceptance

Not claimed for the final implementation head `da52561b`. The required passing
release gate and remotely recoverable exact-commit prerequisites were not met.
Consequently the final clean-state, exact-commit, archive checksum, backup,
apply, real-user, and cleanup gates were not met. No connection was made to the
development host for the final head, and production was never contacted.

## Local evidence

Current local implementation head: `da52561b`.

Passed locally: Bash syntax checks; owner lifecycle; package integration;
shell-access concurrency; exact sudo installation (including `visudo`);
broker access; shell stdin; malicious-input policy; general policy; owner
isolation; Docker readiness; canonical-policy byte comparison; the executable
39-operation broker matrix; package-form and documentation checks; transaction
and repeated-source regressions; and `git diff --check`.

Independent specification and final security/code-quality reviews approved the
local implementation after remediation of quota arithmetic, transactional
installer rollback, revision-zero add apply, full/per-owner reconciliation
locking, hard-link and POSIX ACL authority checks, legacy forced-propagation
bounds, and Compose loader idempotence/failure propagation.

## Release-gate status

A resource-safe sequential `test/compose/run-production-readiness.sh` run at
`79727c58` completed ShellCheck without diagnostics and passed nearly all
Compose shell suites. It then failed in `test-transaction.sh` because
`shell-access.sh` could not be sourced twice in one process. Commits
`453721c7` and `da52561b` fix that issue; the focused shell-access and
transaction suites pass and the fix is independently approved.

The operator prohibited further broad ShellCheck and expensive full-suite runs
on this constrained workstation after severe machine lag and terminal-session
crashes. Therefore the complete readiness gate has not been rerun at
`da52561b`, and no release-gate PASS is claimed. A repository-owned constrained
launcher is now available at
`test/compose/run-production-readiness-limited.sh`; it must be used to rerun
the canonical gate with suitable cgroup limits before development deployment.
The gate's optimized ShellCheck phase analyzes 101 adapters locally and
follows the 42-helper Compose graph once. That phase passed in approximately
25 seconds inside a constrained scope, replacing the previous per-adapter
graph expansion that took roughly 24 minutes.

The root integration test returned `SKIP: root-only disposable integration`.
It deliberately skips unless it is running in an explicitly approved
disposable container; it never changes developer-host users, groups, or
sudoers.
