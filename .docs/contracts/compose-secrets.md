# Compose Secrets Contract

## Storage

Authoritative managed secret values live at:

```text
/usr/local/vesta/data/users/<user>/docker-projects/<project>/secrets/<name>
```

Names match `^[a-z][a-z0-9_-]{0,62}$`. The directory is root-owned mode 0700;
each regular, non-symlink file is root-owned mode 0600. Values are never
accepted as CLI arguments. Create/change commands accept a root-readable input
file descriptor or protected temporary file and remove the temporary file
after an atomic install.

Bundle-managed workloads use container-readable runtime copies at
`runtime/workload-secrets/current/<name>`. Before every start-like lifecycle
action, while holding the project lock, Vesta snapshots the exact declared
authoritative files through no-follow descriptors into a temporary mode-0700
directory, writes authority-owned mode-0444 files, fsyncs them, and atomically
activates the directory. The parent remains authority-owned mode `0700`, so
host users cannot traverse to the readable files while the container runtime
can mount each declared file read-only. A failed refresh leaves the previous
complete set active. These copies are disposable runtime state: revisions,
backups, restore payloads, UI, audit, logs, and exported definitions exclude
them, and project removal removes them with the runtime control root.

Public metadata contains exactly secret name, target path, availability
status, opaque version, creation time, and rotation time. Versions are
cryptographically random 128-bit values encoded as 32 lowercase hexadecimal
characters. Creation issues the first version and leaves rotation time empty;
each successful rotation issues a unique new version while preserving
creation time. Generation retries collisions eight times and then fails
without mutation.

The content SHA-256 used for encrypted backup and restore integrity lives only
in separate root-owned mode-0600 private metadata. It is never returned by
list or web surfaces. Read-only listing projects legacy metadata into the
public schema in memory without exposing its digest or rewriting stored state.
Legacy entries that predate opaque versions use the stable, non-sensitive
compatibility projection `VERSION=unavailable` and
`STATUS=migration-required`. A later explicit create/rotation migration writes
the first cryptographically random version; read-only listing never does.

## Mounting

- Secrets are mounted read-only through Compose secrets or a long-form
  read-only bind to a declared target.
- Bundle Compose files reference only the stable protected runtime-copy path;
  they never mount the authoritative mode-0600 files directly.
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
