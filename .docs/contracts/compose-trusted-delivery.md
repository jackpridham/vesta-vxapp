# Compose Trusted Delivery Contract

## Identity and evidence

Registry-backed image evidence records the immutable repository reference and
`sha256` digest, the local image ID, and only these bounded OCI labels:
`source`, `revision`, `version`, `vendor`, and `created`. Each label is at most
512 characters. Control characters, credential-like values, URI userinfo, and
unknown labels are replaced with an empty value; image environment values are
not copied.

Web preview/session payloads accept those current-image fields only through an
explicit nested schema. OCI labels retain the same five-key,
512-character, control/credential/userinfo-free boundary. Trust decisions
accept only the documented mode, decision, profile/policy versions,
adapter state/detail, threshold, created time, and exception flag. Unknown
fields or any uploaded source path make the complete preview fail closed.

Protected evidence lives below
`/usr/local/vesta/data/vx/compose/image-trust/evidence/<digest>/`, outside
tenant-writable and backup paths. SBOM and provenance documents are root-owned
0600 files. Their public metadata is limited to attachment type, SHA-256,
generator, created time, and verification state.

Evidence and decisions are serialized by a protected per-digest lock.
Pre-existing evidence must match the immutable reference, daemon image ID, and
complete sanitized OCI-label object before reuse. A caller receives the result
created by its own locked invocation, never a concurrently replaced profile
decision.

## Policy modes

`VX_DOCKER_TRUST_MODE` and a profile-specific
`VX_DOCKER_TRUST_MODE_<PROFILE>` select:

- `disabled`: adapters are not run. Local image acceptance remains available
  only through the existing recorded-image/profile approval rules.
- `audit`: all adapter states are recorded but do not block acceptance.
- `enforce`: both adapters must pass, or a current digest-, profile-version-,
  and policy-version-bound root exception must apply.

An invalid mode is an error. Audit or enforce requires a registry digest and
never falls back to local image acceptance. Offline, unavailable, timeout,
invalid output, and adapter failure are explicit non-pass states. Enforce is
fail-closed.

## Adapter interface

Fixed executable names `signature` and `vulnerability` are discovered only
under `/usr/local/vesta/func/vx/compose/trust-adapters/` (or the test override).
They receive exactly three arguments: immutable `sha256` digest, protected
evidence directory, and threshold (`none` for signatures). They receive no
registry credential, owner, project, tag, secret, or tenant path.

The controller starts adapters from the fixed protected trust root with an
empty environment, `/dev/null` stdin, inherited descriptors closed, raw stderr
discarded, an 8-KiB stdout file limit, and the configured wall-clock timeout.

An adapter must finish within 1–60 seconds and emit exactly:

```json
{"SCHEMA":1,"ADAPTER":"signature","STATE":"pass","DETAIL":"bounded summary"}
```

State is `pass`, `fail`, `offline`, or `unavailable`; detail is at most 256
characters. Raw stderr is discarded. The controller maps timeouts and invalid
or failed output to redacted states.

Vulnerability thresholds are `low`, `medium`, `high`, or `critical`. Exception
documents are root-owned 0600 JSON below `image-trust/exceptions/`, have
`AUTHORITY: root`, expire at a UTC time, and bind the exact digest, profile,
profile version, and policy validator version.

## Updates

The update-candidate command performs manifest lookups for both the recorded
immutable reference and candidate tag. It compares the same `linux/amd64`
platform-manifest digest on each side, while separately retaining the recorded
registry/index digest. It does not pull, tag, remove, or deploy an image.
Adoption of a candidate digest still uses immutable preview/apply.

## Credential-free BuildKit fixture

`test/compose/fixtures/buildkit-trust/generate-evidence.sh` builds the local
fixture to an OCI archive with BuildKit SBOM and provenance enabled. It uses no
registry reference, login, push, credential file, or repository secret. If the
installed BuildKit lacks attestations, that is an explicit unavailable tooling
state; it is not evidence that trust verification passed.
