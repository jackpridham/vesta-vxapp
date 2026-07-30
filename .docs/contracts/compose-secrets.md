# Compose Secrets Contract

## Storage

Managed secret values live only at:

```text
/usr/local/vesta/data/users/<user>/docker-projects/<project>/secrets/<name>
```

Names match `^[a-z][a-z0-9_-]{0,62}$`. The directory is root-owned mode 0700;
each regular, non-symlink file is root-owned mode 0600. Values are never
accepted as CLI arguments. Create/change commands accept a root-readable input
file descriptor or protected temporary file and remove the temporary file
after an atomic install.

Metadata may contain secret name, target path, ownership request, creation
time, rotation time, and SHA-256 for change detection. It never contains the
value.

## Mounting

- Secrets are mounted read-only through Compose secrets or a long-form
  read-only bind to a declared target.
- Targets default to `/run/secrets/<name>`.
- A secret cannot be mounted over a system binary, Docker socket, device, or
  another protected path.
- Secret values cannot be interpolated into environment, command,
  healthcheck, labels, or route metadata.
- Inspect/list/web responses expose only redacted metadata.

## Rotation and deletion

Rotation atomically replaces the host file, preserves mode/ownership, records
an audit event, and optionally recreates affected services after policy
validation. Deletion is refused while a current revision references the
secret. All failures are redacted.

## Backup

Unencrypted backups never contain secret values. They contain a secret
manifest so restore can report required names.

Encrypted secret backup is enabled only when Vesta has:

- an installed `age` binary;
- a validated public recipient in root-owned global configuration;
- a successful encryption self-test.

Values are streamed into a separate `.age` payload without plaintext archive
files. The private key is never stored in Vesta user data or backups. Restore
decrypts to a protected temporary directory, verifies names/modes, installs
atomically, and removes plaintext temporaries. Without the recipient/private
key workflow, restore ends in `restore-required` until the operator
re-provisions secrets.

## Disclosure tests

Synthetic canaries must be absent from metadata, list/inspect output, audit
history, Docker command logs, Compose validation errors, web HTML/JSON,
unencrypted backups, and routine container logs.

## Exact-image secret consumers

An image that does not natively read Compose secret files may use a reviewed
executable stored in an existing managed volume. Compose may invoke that
executable by its non-sensitive container path; the executable may then read
the root-owned `/run/secrets/<name>` mount. The wrapper must contain no secret
value, remain inside backup/restore coverage, and pass the same canary tests.

For the current `slave-vxapp` exact-image rehearsal, `LOG_LEVEL=info` is a
non-secret literal runtime setting. It prevents Laravel's debug-level tenant
detection message from exposing the protected `TENANT_DETECTION` value.
Routine log capture must still prove the canary absent; configuration alone is
not acceptance evidence.
