# Compose Self-Service Deployment Contract

## Non-negotiable behavior

- A non-admin actor can act only as the same Vesta owner and only with profile
  `standard`.
- The new stage/apply interface accepts only `standard`. Existing
  `admin-approved` administrator paths are not accepted by the self-service
  preview commands.
- Preview performs no project, Docker, route, profile-assignment, or secret
  mutation.
- Staging copies protected `/tmp/vx-compose-web.<32 hex>/compose.yaml` exactly
  once to `source.compose.yaml` in a root-owned mode-0700 preview directory;
  source hashing and canonicalization use only that immutable copy. The
  generated, policy-checked candidate is stored separately as `compose.yaml`
  and is the only definition passed to apply and persistent project storage.
- Standard-project confirmation supplies and verifies `PREVIEW_ID`, `SOURCE_SHA256`,
  `CANDIDATE_SHA256`, and `EXPECTED_CURRENT_REVISION`.
- Missing, expired, linked, replaced, incorrectly owned/mode, digest-mismatched,
  or stale previews fail before desired state or Docker changes.
- The same project lock is held across expected-revision verification,
  revision installation, deploy/health/route convergence, and rollback.
- Definition export revalidates stored desired state and refuses output if any
  non-empty managed-secret line occurs in the source. Generated stored
  definitions must have exact ownership identity; export removes only those
  validated system-generated labels and runtime names, revalidates the
  resulting editable definition, and binds the returned bytes to
  `SOURCE_SHA256`.
- Plans never contain secret values, registry authentication, caller
  environment, or unredacted Docker errors.
- Persistent application data is never represented as definition rollback.
- The implementation has passed disposable-staging and production acceptance.
  Production project `slave/slave-vxapp` is Vesta-managed at revision 4 as of
  2026-07-31. This contract does not authorize a production mutation:
  production remains read-only without separate explicit authorization naming
  the target, release, and workload scope. No firewall mutation or Docker
  prune is permitted.

## Stable interfaces

```text
v-plan-docker-project-source USER PROJECT SOURCE PROFILE MODE
v-list-docker-project-definition USER PROJECT FORMAT
v-stage-docker-project-preview ACTOR OWNER PROJECT SOURCE PROFILE MODE
v-apply-docker-project-preview ACTOR OWNER PROJECT PREVIEW_ID \
    SOURCE_SHA256 CANDIDATE_SHA256 EXPECTED_CURRENT_REVISION
```

`MODE` is exactly `add` or `change`. Preview IDs are 32 lowercase hex
characters. Digests are 64 lowercase hex characters. Expected revision is `0`
for add and a positive integer for change.

Successful stage output is JSON:

```json
{
  "VALID": true,
  "PREVIEW_ID": "0123456789abcdef0123456789abcdef",
  "OWNER": "alice",
  "PROJECT": "shop",
  "PROFILE": "standard",
  "MODE": "change",
  "SOURCE_SHA256": "64-lowercase-hex",
  "CANDIDATE_SHA256": "64-lowercase-hex",
  "EXPECTED_CURRENT_REVISION": 3,
  "EXPIRES_AT": "UTC timestamp",
  "SERVICES": {
    "ADDED": [],
    "REMOVED": ["worker"],
    "CHANGED": ["web"],
    "UNCHANGED": []
  },
  "ROUTES": {
    "UNCHANGED": [],
    "INVALIDATED": [],
    "RETARGET_REQUIRED": []
  }
}
```

The preview directory is:

```text
/usr/local/vesta/data/tmp/compose-previews/<preview-id>/
  source.compose.yaml
  compose.yaml
  canonical.json
  canonical.sha256
  policy.conf
  manifest.sha256
  preview.conf
```

The directory is root-owned mode `0700`; all files are root-owned, regular,
non-symlink files and mode `0600`. `source.compose.yaml` is the byte-exact
submitted source bound by `SOURCE_SHA256`; `compose.yaml` is the generated
candidate with enforced runtime ownership labels. `manifest.sha256` binds both
forms plus `canonical.json`, `canonical.sha256`, and `policy.conf`.
`preview.conf` contains only single-quoted validated metadata:

```text
ACTOR='alice'
OWNER='alice'
PROJECT='shop'
PROFILE='standard'
MODE='change'
SOURCE_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
CANDIDATE_SHA256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
POLICY_SHA256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
EXPECTED_CURRENT_REVISION='3'
CREATED_EPOCH='1785200400'
EXPIRES_EPOCH='1785201300'
```
