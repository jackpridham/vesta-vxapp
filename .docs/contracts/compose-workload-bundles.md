# Compose Workload Bundle Contract

## Purpose and authority

A workload bundle is an application-supplied, application-neutral description
that Vesta can validate and install as a managed Compose project. The bundle
does not bypass canonical Compose rendering, profile assignment, image
approval, policy, quota, secret, revision, lock, or lifecycle checks. Vesta
remains authoritative for project ownership and accepted desired state.

The wire format is one deterministic gzip-compressed POSIX ustar archive
containing exactly these three root-level regular files, once each and with no
other entries:

```text
workload.json
compose.yaml
manifest.sha256
```

The ustar members occur in ASCII lexical order: `compose.yaml`,
`manifest.sha256`, then `workload.json`. Every header uses mode `0600`, numeric
UID/GID `0`, size from the member bytes, modification time `0`, regular-file
type, and empty owner/group names. It contains no PAX, GNU, sparse, extension,
or long-name headers and ends with exactly two zero blocks. Directories,
links, devices, FIFOs, path separators, absolute or dot-prefixed paths,
duplicate names, and trailing tar blocks or data are rejected.

The gzip wrapper is one non-concatenated stream with the fixed ten-byte header
`1f 8b 08 00 00 00 00 00 02 03`: deflate, no optional fields, modification
time zero, maximum-compression flag, Unix origin. Its CRC32 and input-size
trailer must match the single expanded ustar stream. Concatenated members,
optional gzip headers, and bytes after the one gzip trailer are rejected.

## Protected input and extraction

The archive and its separately supplied checksum file must each be a
root-owned regular non-symlink file with mode `0600` in an accepted protected
staging directory. The checksum file contains exactly one line in
`sha256sum` format for the archive's validated basename. It permits only a
lowercase 64-character SHA-256 value, two spaces, the basename, and one final
newline. The archive is hashed from one opened file descriptor and verified
before it is inspected or extracted.

The hard limits are:

- compressed archive: 64 MiB;
- expanded ustar stream: 4 MiB;
- `workload.json`: 256 KiB;
- `compose.yaml`: 1 MiB;
- `manifest.sha256`: 256 bytes;
- total extracted regular-file bytes: 2 MiB;
- validation or plan output: 32 KiB.

An administrator may configure smaller limits, never larger ones. Decompression,
listing, and extraction run without caller environment or tenant-controlled
options in a new root-owned mode-0700 directory on the same filesystem as
protected staging. The controller bounds compressed bytes before parsing and
expanded bytes while inflating, validates the single gzip stream and complete
ustar member table before extraction, extracts without following or preserving
links, ownership, permissions, extended attributes, ACLs, capabilities, or
timestamps, and then revalidates the exact regular-file set, ownership, modes,
byte counts, and opened-file identities. Files become root-owned mode `0600`.
Any limit, identity, gzip, member, type, parser, or checksum failure removes
the disposable extraction directory and causes no project, image, secret,
route, or runtime mutation.

`manifest.sha256` contains exactly two lines, in this order, with one final
newline:

```text
<lowercase SHA-256><two spaces>workload.json
<lowercase SHA-256><two spaces>compose.yaml
```

Both hashes are checked from already-opened extracted files. Bundle identity
is the SHA-256 of the original archive bytes; workload identity is the
SHA-256 of the exact `workload.json` bytes. The accepted revision persists the
exact manifest bytes, all three member hashes, the archive hash, and the
canonical Compose hash. JSON producers use UTF-8, no byte-order mark, sorted
object keys, compact separators, JSON integer syntax, and one final newline so
equivalent generated manifests have deterministic bytes. Vesta rejects
duplicate JSON keys, unknown fields, invalid UTF-8, non-integer numbers, and
non-canonical workload JSON.

## Workload manifest schema 1

`workload.json` is one JSON object with exactly these fields:

```json
{
  "schema": 1,
  "workload": {
    "id": "application-id",
    "release": "release-id"
  },
  "profile": {
    "name": "admin-approved",
    "version": 3
  },
  "image": {
    "reference": "local/application:release-1",
    "id": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    "os": "linux",
    "architecture": "amd64"
  },
  "services": [
    {
      "name": "service",
      "image": "local/application:release-1"
    }
  ],
  "resources": {
    "cpus": "1.000",
    "memory_mib": 512,
    "pids": 128
  },
  "ports": [
    {
      "service": "service",
      "host_ip": "127.0.0.1",
      "host_port": 8080,
      "container_port": 8080,
      "protocol": "tcp"
    }
  ],
  "secrets": [
    {
      "name": "credential",
      "target": "/run/secrets/credential"
    }
  ],
  "volumes": [
    {
      "name": "state",
      "service": "service",
      "target": "/var/lib/application"
    }
  ],
  "health_timeout_seconds": 120,
  "probes": {
    "ready": {
      "service": "service",
      "argv": ["/usr/local/bin/application-health", "--json"],
      "timeout_seconds": 15,
      "max_output_bytes": 8192
    }
  },
  "compatibility": {
    "orchestrator_api": 1,
    "policy_schema": 1,
    "validator_min": 1,
    "validator_max": 1
  }
}
```

Identifiers are lowercase ASCII slugs no longer than 63 characters. Release
identity is a non-secret printable ASCII value no longer than 128 characters.
Arrays are non-empty where the workload declares the corresponding resource,
contain no duplicates, and are sorted by their stable identity. Service,
image, port, secret, and volume declarations must exactly match the rendered
Compose policy view; aggregate resources must exactly equal the sums of the
rendered per-service limits. The single image declaration applies to every
service in schema 1. `reference` may be a validated local tag only as lookup
intent. It and the declared image ID/platform must match a current local
approval and Docker inspection.

Under the project lock, Vesta resolves the submitted reference again, requires
the exact approved `sha256:<64 lowercase hex>` image ID, operating system, and
architecture, and rewrites every persisted and runtime Compose service image
to that exact image ID. The canonical Compose hash is calculated only after
this rewrite. The submitted tag remains bounded workload intent; it is never
deployment, revision, rollback, or runtime authority. A moved or ambiguous
tag, a missing image ID, or any platform mismatch fails before persistence or
runtime mutation.

Ports use explicit IP, integer host/container port, and `tcp` or `udp`.
Secrets declare names and absolute in-container targets only; values, content
hashes, versions, host paths, and availability are forbidden. Volume entries
declare managed named volumes and in-container targets only. Bind mounts and
application data never enter the bundle archive. Health timeout is an integer
from 1 through 900 seconds. Probe names are lowercase ASCII slugs; their
service and fixed argv are persisted as immutable revision authority under
the project-probe contract.

Each probe argv has 1 through 16 elements. Each UTF-8 element is 1 through 256
bytes, the sum of element bytes is at most 2048, and the first element is an
absolute in-container executable path. NUL, control characters, invalid UTF-8,
and empty elements are rejected. Arguments are data passed directly to exec;
shell parsing, interpolation, and caller additions are forbidden.

Compatibility metadata is declarative, not an exemption. Vesta accepts only
supported orchestrator API, policy schema, and validator ranges and still
records the actual policy, validator, and profile versions used for the
revision.

## Planning and installation

Planning validates the protected archive, checksum, schema, manifest hashes,
profile assignment, current local image approval, rendered Compose model,
policy, quotas, secret declarations, and add/change revision expectation. It
does not load an image, read a secret value, mutate desired state, or contact
the workload.

Installation consumes the same verified archive identity under the project
lock, revalidates all external authority, installs `workload.json` and its
hash evidence with the immutable revision, and uses the existing lifecycle
transaction for convergence or rollback. Secret values are provisioned only
through the protected secret interfaces and are never bundle members.

For `MODE=add`, a manifest that declares secrets requires one separately
supplied `SECRETS_DIRECTORY`; a manifest without secrets rejects it. The
directory is forbidden for `MODE=change`, which reuses the current project's
managed secret values. The supplied path must resolve directly inside an
accepted protected staging root to an authority-owned actual directory, not a
symlink, with mode `0700`. Production authority is root; non-root tests use
their configured test authority.

The directory contains exactly one entry per declared secret name and no
other entry. Each entry name exactly matches the manifest name and is an
authority-owned regular non-symlink mode-`0600` file. Nested directories,
links, devices, FIFOs, sockets, undeclared names, missing names, and duplicate
filesystem identities are rejected. Each file is at most 1 MiB and aggregate
secret input is at most 8 MiB; administrators may configure smaller limits,
never larger ones.

Under the project lock, the importer opens the directory without following
links through its validated protected parent descriptor, snapshots both
bindings, opens and snapshots every input file without following links, and
verifies parent, directory, and file identities before and after copying. It
validates each name and value through the existing
managed-secret helpers, then atomically installs the values into the new
project's temporary root before that root is published or deployment begins.
A failure removes the unpublished project root and installs no partial
project. The import transaction never places secret values in bundle members,
revision files, or backup payloads.

Abstract external Compose secret declarations are normalized during import to
stable paths below the protected runtime secret-copy directory. Immediately
before each start-like convergence, Vesta atomically refreshes that exact
declared set from authoritative mode-0600 files. Runtime copies are
authority-owned mode `0444` below an authority-owned mode-0700 parent and are
never revision or backup members.

The importer neither changes nor removes the caller-supplied directory. The
caller owns cleanup after every success or failure; an application CLI that
creates the directory must install an exit/signal trap before writing values
and remove only that exact validated temporary directory. Planning has no
secret-directory input and never opens or reads secret values.

The supplied directory path, file paths, values, content hashes, and private
validation details never appear in stdout, stderr, plans, list output, audit,
operation state, revision metadata, or public/private bundle metadata. Only
declared secret names, in-container targets, availability, and the ordinary
opaque managed-secret versions may be retained under the existing secret
contract. Values are never command-line arguments.

Bundle metadata, plans, list output, and audit contain only bounded workload
identity, release, profile and validator versions, immutable image identity,
declared names/targets, resource and port summaries, hashes, actor, result,
and redacted errors. Unknown output fields, credential-like text, control
characters, caller paths, and archive content are not surfaced.
