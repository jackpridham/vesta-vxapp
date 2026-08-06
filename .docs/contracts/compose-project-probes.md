# Compose Project Probe Contract

## Immutable probe authority

A project probe is a bounded application-defined diagnostic executed by the
generic Vesta orchestrator. The caller selects only an owner, project, and
probe name. The service, argv vector, timeout, and output limit come solely
from the schema-1 `workload.json` stored in the current immutable,
manifest-verified revision. A request fails closed if the project revision,
workload manifest, profile assignment, image identity, service ownership, or
probe declaration no longer verifies.

Probe names are not shell fragments. Vesta never accepts a caller-supplied
command, argument, environment assignment, working directory, user, or
container identifier. Probe execution does not alter desired state, start a
stopped service, publish a port, mount additional content, or grant additional
capabilities.

## Execution boundary

Vesta resolves exactly one running container whose Compose and Vesta ownership
labels match the selected project and declared service. It executes the
persisted argv directly without a shell, with stdin closed, an empty
environment, inherited file descriptors closed, no TTY, and no privilege or
user override. The execution starts only after acquiring a bounded read-side
project/revision identity check and rechecks container identity before
returning a result.

Manifest timeouts are integers from 1 through 60 seconds. Manifest output
limits are integers from 256 through 8192 bytes. The controller independently
enforces those ceilings, captures stdout and stderr separately in protected
mode-0600 temporary files, kills only the exact timed-out exec process, and
removes capture files on every exit. Truncation is a non-pass state. Raw
stderr is never returned. No probe can run concurrently more than once per
project, and global/per-owner concurrency limits prevent probe execution from
becoming a host resource-amplification path.

## Workload output schema 1

The probe executable must emit one UTF-8 JSON object and one final newline on
stdout, with no leading or trailing bytes:

```json
{"schema":1,"state":"pass","summary":"bounded non-sensitive summary","observations":{"check":"ok"}}
```

The exact allowed top-level fields are:

- `schema`: integer `1`;
- `state`: `pass`, `fail`, or `unavailable`;
- `summary`: printable UTF-8 string of at most 256 bytes;
- `observations`: object with at most 16 unique lowercase ASCII slug keys and
  printable string values of at most 256 bytes each.

All fields are required. Nested objects/arrays, numbers or booleans in
observations, duplicate keys, unknown fields, invalid UTF-8, control
characters, ANSI escapes, URI userinfo, absolute host paths, and more than
4096 decoded JSON bytes are invalid output. Process failure, timeout,
truncation, malformed output, identity drift, or schema rejection can never
produce `pass`.

## Secret rejection and redaction

Probe output is untrusted even when the image is approved. Before persistence
or display, Vesta rejects output containing any current managed-secret bytes
or protected synthetic disclosure canary. It also rejects credential-like
keys or delimiter-bounded terms and values, including password, passwd,
secret, token, auth, authorization, bearer, private key, access key, API key,
session, cookie, credential, and URI userinfo forms, case-insensitively.
Secret values are compared only inside the protected controller and are never
copied into argv, environment, audit, result metadata, or error details.

After validation, the controller normalizes each retained string to the
documented byte limit and applies the common control-plane redactor. Any
redaction match changes the probe result to `invalid-output`; partially
redacted workload output is never represented as an authentic application
result. Raw stdout, raw stderr, Docker exec errors, and rejected JSON are
discarded after a bounded generic diagnostic is produced.

## Controller result schema 1

JSON command output uses stable uppercase Vesta keys:

```json
{
  "SCHEMA": 1,
  "OWNER": "alice",
  "PROJECT": "shop",
  "PROBE": "ready",
  "SERVICE": "service",
  "REVISION": 3,
  "WORKLOAD_SHA256": "64-lowercase-hex",
  "STATE": "pass",
  "SUMMARY": "bounded non-sensitive summary",
  "OBSERVATIONS": {"check":"ok"},
  "EXIT_CODE": 0,
  "DURATION_MS": 125,
  "OBSERVED_AT": "UTC timestamp"
}
```

`STATE` is `pass`, `fail`, `unavailable`, `timeout`, or `invalid-output`.
`EXIT_CODE` is an integer from 0 through 255 or `null` when no safe exit code
exists. Unknown result fields are forbidden. Human output projects the same
bounded fields and never includes raw capture content.

Audit records contain only actor, owner, project, probe name, declared
service, revision and workload hashes, image ID, profile/policy/validator
versions, controller state, exit code, duration, observation time, and a
bounded redacted diagnostic category. They exclude argv, environment,
container IDs, temporary paths, secret metadata/content, observations, raw
summary, stdout, stderr, and Docker daemon errors.
