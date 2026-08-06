# Compose Workload Bundle Contract

## Purpose and authority

A workload bundle is an application-supplied, application-neutral description
that Vesta can validate and install as a managed Compose project. The bundle
does not bypass canonical Compose rendering, profile assignment, image
approval, policy, quota, secret, revision, lock, or lifecycle checks. Vesta
remains authoritative for project ownership and accepted desired state.

The archive is a tar file containing exactly these three root-level regular
files, once each and with no other entries:

```text
workload.json
compose.yaml
manifest.sha256
```

Directories, links, devices, FIFOs, sparse files, path separators, absolute or
dot-prefixed paths, duplicate names, extended headers, and trailing archive
members are rejected. Member order is not authority; deterministic identity
comes from the member bytes and hashes.

## Protected input and extraction

The archive and its separately supplied checksum file must each be a
root-owned regular non-symlink file with mode `0600` in an accepted protected
staging directory. The checksum file contains exactly one line in
`sha256sum` format for the archive's validated basename. It permits only a
lowercase 64-character SHA-256 value, two spaces, the basename, and one final
newline. The archive is hashed from one opened file descriptor and verified
before it is inspected or extracted.

The default hard limits are:

- archive: 64 MiB;
- `workload.json`: 256 KiB;
- `compose.yaml`: 1 MiB;
- `manifest.sha256`: 256 bytes;
- total extracted regular-file bytes: 2 MiB;
- validation or plan output: 32 KiB.

An administrator may configure smaller limits, never larger ones. Listing and
extraction run without caller environment or tenant-controlled options in a
new root-owned mode-0700 directory on the same filesystem as protected
staging. The controller validates the archive member table before extraction,
extracts without following or preserving links, ownership, permissions,
extended attributes, ACLs, capabilities, or timestamps, and then revalidates
the exact regular-file set, ownership, modes, byte counts, and opened-file
identities. Files become root-owned mode `0600`. Any limit, identity, member,
type, parser, or checksum failure removes the disposable extraction directory
and causes no project, image, secret, route, or runtime mutation.

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
    "reference": "repository/name@sha256:immutable-digest",
    "id": "sha256:local-image-id",
    "os": "linux",
    "architecture": "amd64"
  },
  "services": [
    {
      "name": "service",
      "image": "repository/name@sha256:immutable-digest"
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
rendered per-service limits. The single immutable image declaration applies
to every service in schema 1. Its reference and local ID must match a current
local approval as well as Docker inspection.

Ports use explicit IP, integer host/container port, and `tcp` or `udp`.
Secrets declare names and absolute in-container targets only; values, content
hashes, versions, host paths, and availability are forbidden. Volume entries
declare managed named volumes and in-container targets only. Bind mounts and
application data never enter the bundle archive. Health timeout is an integer
from 1 through 900 seconds. Probe names are lowercase ASCII slugs; their
service and fixed argv are persisted as immutable revision authority under
the project-probe contract.

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

Bundle metadata, plans, list output, and audit contain only bounded workload
identity, release, profile and validator versions, immutable image identity,
declared names/targets, resource and port summaries, hashes, actor, result,
and redacted errors. Unknown output fields, credential-like text, control
characters, caller paths, and archive content are not surfaced.
