# Compose Images, Archives, and Registry Contract

The optional Vesta-managed registry is only a source of immutable OCI digest
evidence. Publisher access cannot create previews, change desired state, or
deploy. Tenants submit exact `registry/namespace/repository@sha256:<digest>`
references through the existing preview, pull, and apply workflow.

## Image policy

Every service uses an immutable digest for deployment evidence. A submitted tag
may be retained as operator intent, but the accepted revision records the
resolved repository digest and local image ID. Builds on the managed host are
rejected.

## Administrator pull

`v-pull-docker-image` accepts owner and image reference, uses the owner's
protected Docker config, pulls explicitly, verifies the resulting reference,
architecture, and image ID, and records a redacted audit event. Policy may
restrict registries and image patterns by profile. This command does not
create tenant `registry-pull` provenance.

## Preview-bound tenant pull

The only tenant pull form is:

```text
v-docker image-pull PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 \
  REVISION IMAGE@sha256:DIGEST
```

The owner is kernel/sudo-derived and profile authority is fixed to `standard`.
No owner, actor, profile, tag, URL, platform, credential, or Docker option is
accepted. Under the project lock, the dedicated adapter verifies the exact
unexpired protected preview, current expected revision, and that the image
occurs exactly once in its `canonical.json`.

Lock order is owner access, project, global tenant pull, then owner registry.
Using only the owner's protected Docker configuration, the adapter inspects
the manifest before pull. A single manifest must be Linux on the approved
architecture; an index must contain exactly one such child, which is inspected
separately. Manifest output is limited to 1 MiB, inspection and pull have fixed
root-controlled timeouts, and raw Docker output is discarded. Config and layer
sizes must be non-negative integers with a positive overflow-safe total no
greater than `VX_COMPOSE_IMAGE_MAX_BYTES`; at most 128 layers are accepted.
Every descriptor requires a SHA-256 digest. Foreign URLs and foreign or
nondistributable media types are rejected. Malformed, ambiguous,
wrong-platform, zero-sized, and oversized manifests fail before Docker image
mutation.

Post-pull inspection must report the exact requested repository digest, an
exact SHA-256 image ID, Linux, the approved architecture, and a positive local
Docker size no greater than `VX_COMPOSE_IMAGE_MAX_BYTES`. Protected owner
metadata identifies delivery as `registry-pull` and binds the image, platform
manifest, admitted and local sizes, project, preview ID, source/candidate
digests, and expected revision. The record is a bounded, single-link,
root-owned mode-0600 authorization file with an exact schema and durable
replacement. New evidence is first durable but non-authoritative `pending`
state. The owner registry lock remains held across backup, pull, pending write,
audit, activation, and restoration. Audit records started and a durable
`succeeded` event before the record is atomically activated; the audit file and
its directory are synced before activation. If activation does not complete,
the prior authority is restored and a later `failed` event records the terminal
outcome. A crash can leave only rejected pending evidence, never unaudited
active authority. Tenant output is a small redacted result, not the
authorization record. Docker `RepoDigests` alone is runtime evidence, not pull
provenance.

## Private registries

Registry credentials live in:

```text
/usr/local/vesta/data/users/<user>/docker-registry/config.json
```

The directory/file are root-owned 0700/0600. Password/token input is supplied
by file, never argv. Docker operations set `DOCKER_CONFIG` to that directory.
List and web interfaces return registry host, username label if approved,
created/rotated timestamps, and last validation result—never `auth`, password,
identity token, or raw config.

## Local archives

Image loading requires:

- a regular non-symlink archive in a root-controlled staging directory;
- a separately supplied SHA-256 file with exactly one allowed filename;
- successful `sha256sum -c`;
- archive size within the administrator limit;
- `docker image load` output parsed without treating it as identity proof;
- post-load inspection of architecture, OS, image ID, tags, and repo digests;
- policy approval of the resulting identity.

Archives are not committed or placed in user backups. Temporary archives are
removed after a successful load unless the operator requests retained
quarantine storage.

## Local image approvals

Loading an archive makes image bytes available to Docker; it does not grant a
project permission to use them. A separate administrator action may approve
one inspected local identity for one owner and one installed profile version.
The protected approval binds all of:

- owner;
- submitted image reference and exact local `sha256` image ID;
- inspected operating system and architecture;
- profile name and version;
- policy schema and validator version;
- approving actor;
- creation UTC timestamp and mandatory expiry UTC timestamp.

For a loaded local image, the reference may be a tag only as lookup intent; it
is never deployment authority or a mutable substitute for the image ID.
Approval is valid only while Docker inspection resolves that reference to the
exact recorded ID, operating system, and architecture and the recorded
profile, policy, and validator versions remain installed and supported. Under
the project lock, bundle import resolves it again and rewrites persisted and
runtime Compose image fields to the exact `sha256:<64 lowercase hex>` image
ID. Expired, missing, mismatched, ambiguous, or replaced identities fail
closed before candidate persistence or runtime mutation. Approval does not
waive registry trust when the selected trust mode requires registry evidence,
and it never authorizes a build on the managed host.

Approvals live in root-owned mode-0700 control storage outside tenant data and
backups; each record is a regular non-symlink mode-0600 file. List and audit
surfaces return only the bound identity and versions, actor, timestamps,
expiry state, and redacted decision. Revocation removes authority for future
validation and start-like actions but never removes image layers, revisions,
containers, or project data. Image removal and global prune remain separate
and are not implied.

Schema-1 workload bundles consume this authority as defined by
[Compose workload bundles](compose-workload-bundles.md).

For `standard` resolution, authority is either matching secure
`registry-pull` provenance for an immutable submitted reference or a matching
unexpired administrator approval for the current image identity and installed
standard/profile policy versions. A tag or locally built image does not become
registry-delivered merely because Docker 29 reports a `RepoDigests` entry.
Exact accepted-revision compatibility is available only while refreshing the
identical protected service/reference/image-ID/digest/platform tuple from a
valid schema-2 revision or the exact five-field legacy authority. It is never
passed to add/change candidate resolution, never synthesizes pull provenance,
and historical evidence bytes are never rewritten by this rule.

## Updates and rollback

Update resolves/pulls images before runtime mutation. The prior revision
records exact image IDs. Rollback refuses if a required prior image is absent
unless it can be pulled by digest; it never silently substitutes a newer tag.

Registry trust evidence, SBOM/provenance attachments, verifier modes, and
manifest-only update detection are defined by
[Compose trusted delivery](compose-trusted-delivery.md).
