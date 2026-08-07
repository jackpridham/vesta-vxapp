# Compose Shell Access Development Validation — 2026-08-07

## Scope

Milestone 3 local implementation and disposable validation for derived group
membership, exact broker-only sudo installation, and tenant shell revocation.

## Development-host acceptance

Not claimed. The required release commit did not exist until this milestone
was committed, and no evidence was available that the remote branch contained
that exact commit. Consequently the clean-state, exact-commit, remote-branch,
archive checksum, backup, apply, real-user, and cleanup gates were not met.
No connection was made to the development host or to production.

## Local evidence

Implementation commit: `e80485ca`.

Passed locally: Bash syntax checks; owner lifecycle; package integration;
shell-access concurrency; exact sudo installation (including `visudo`);
broker access; shell stdin; malicious-input policy; general policy; owner
isolation; Docker readiness; canonical-policy byte comparison; and
`git diff --check`.

The root integration test returned `SKIP: root-only disposable integration`.
It deliberately skips unless it is running in an explicitly approved
disposable container; it never changes developer-host users, groups, or
sudoers.
