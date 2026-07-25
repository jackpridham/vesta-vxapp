# Compose Backup and Restore Contract

## Backup contents

A project backup includes:

- canonical Compose and non-secret variables;
- project/profile/policy metadata;
- route metadata;
- audit history for the project;
- revision manifests needed for rollback;
- managed bind data selected by policy;
- managed named-volume data captured from a fixed, reviewed helper image;
- image identity manifest, not image layers;
- secret-name manifest;
- optionally, a separately encrypted secret payload under the secrets
  contract.

It excludes registry credentials, Docker daemon state, container writable
layers, build cache, raw image archives, sockets, devices, and unrelated
projects.

## Consistency

Backup takes the project lock. The default application-consistent sequence is:

1. record runtime state;
2. run an approved per-profile pre-backup hook if present;
3. stop services when the profile requires cold backup;
4. archive definitions/data with numeric ownership and path checks;
5. calculate a manifest of SHA-256 hashes;
6. restart only services that were running;
7. verify health/routes;
8. record the backup result.

No broad Docker volume traversal or prune is permitted.

## Restore

Restore always targets an explicit owner/project and supports validation-only.
It:

- rejects traversal, absolute archive members, links escaping the restore root,
  devices, FIFOs, and unexpected files;
- verifies every manifest hash before mutation;
- canonicalizes/policy-checks Compose under current policy;
- verifies image availability by digest;
- restores into a staging root;
- checks package quotas before installing data;
- installs definitions/data atomically;
- restores secrets only through the encrypted-secret workflow;
- deploys and validates health/routes;
- rolls back to the pre-restore revision/data snapshot on failure.

Cross-user restore requires admin authorization and rewrites stable project
identity/labels only after full validation.

## Retention and destructive behavior

Backups are ordinary Vesta backup artifacts and participate in existing
retention. Removing a project never removes its last known-good backup.
The current public project remove command retains data. Any future
volume/data purge must be a separate audited operation with an explicit
confirmation token and backup-state checks.

## Acceptance

Integration tests prove definition, bind, named-volume, route, audit, secret
manifest/encrypted secret, stopped/running state, checksum failure, malicious
archive, quota failure, and failed-health rollback behavior.
