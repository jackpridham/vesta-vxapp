# Publish and Deploy with Vesta-Managed Harbor

> **Current status — do not run this workflow yet.** Development acceptance
> is **BLOCKED — PRODUCT** as of 2026-08-08. Harbor v2.15.0 cannot satisfy the
> approved caller-generated publisher-secret contract through the required
> least-privilege integration identity. The development provider was safely
> returned to `disabled`; its service is inactive/disabled, no Harbor host
> listener or registry socket is present, and production is deferred. See the
> [development acceptance evidence](../validation/2026-08-08-vesta-managed-harbor-development.md),
> recorded at repository commit
> `26b3764595a024b5b830a955b164f0ad95a25a2b`.

This is the canonical tenant workflow **once an administrator confirms that
Vesta-managed Harbor is operational and `registry-info` reports healthy,
fresh, ready state**. It applies to maintainers of any existing tenant-owned
`standard` project. Names such as `slave-vxapp` and `asterisk-vxapp` are only
generic examples; application-specific build, configuration, and acceptance
details belong in the application repository.

The normative provider boundary is the
[Harbor provider contract](../contracts/harbor-provider.md). Administrators
should also use the
[container-orchestration operator guide](../../docs/container-orchestration.md).

## What the managed registry is

Vesta-managed Harbor is a private OCI image store operated as a root-owned
Vesta platform service. Harbor stores image manifests and layers and measures
project usage. Vesta remains the authority for tenant eligibility, namespace
mapping, registry credentials, quota, accepted image evidence, Compose desired
state, revision, health, routes, rollback, backup, revocation, and audit.

The design deliberately avoids a second application delivery system:

- no application team maintains a separate registry service, registry DNS
  record, TLS certificate, public registry port, or Harbor administrator;
- the registry uses the existing Vesta hostname, TLS certificate, and panel
  port returned by `registry-info`;
- Harbor has no public host TCP listener. Vesta's existing TLS listener proxies
  only OCI paths under `/v2/` and the exact token endpoint `/service/token` to
  the protected Harbor Unix socket; the portal, API, and metrics stay private;
- source and Compose travel through the application repository and bounded
  `v-docker` stdin, not SCP, rsync, an image archive, or a Vesta control path;
- tenants receive no Docker socket, Docker group, raw Docker on the managed
  host, Debian sudo, direct `v-*` access, or Harbor administration; and
- an image push never deploys anything. Deployment still requires an immutable
  Vesta preview, preview-bound pull, and apply transaction.

These terms name different things:

| Term | Meaning and authority |
| --- | --- |
| Source repository | Application code, Dockerfile, Compose template, tests, secrets schema, acceptance checks, and deploy adapter owned by the application team. |
| Image | The OCI artifact built and tested from source outside the Vesta host. `IMAGE_NAME` is its local build name in the commands below. |
| Harbor project | Vesta's private owner namespace and quota boundary. Vesta creates and maps it; the tenant cannot administer it. |
| Harbor repository | The exact push path returned as `REPOSITORY` by `registry-info` for `APP_PROJECT`. Do not reconstruct it. |
| Release tag | A temporary, versioned publication label such as `RELEASE_TAG`. A tag can move and is never Vesta deployment authority. |
| Immutable digest | The registry content identity `sha256:` plus 64 lowercase hexadecimal characters. Compose and Vesta use `REPOSITORY@IMAGE_DIGEST`, never the tag. |

## Eligibility and SSH boundary

Once the provider is operational, recurring releases use the ordinary tenant
account over SSH and need no per-release Debian administrator approval. The
account must be a matching Unix/Vesta account, non-administrator, unsuspended,
configured with an interactive Bash shell, and assigned positive or
`unlimited` effective `DOCKER_PROJECTS` and `DOCKER_REGISTRY_MB` limits. The
target must already be that owner's `standard` Compose project; the current
broker verifies it before `registry-info`.

`DOCKER_REGISTRY_MB` is the administrator-assigned Harbor storage limit.
`U_DOCKER_REGISTRY_MB` is Vesta's system-maintained observation of Harbor
usage. Tenants and packages do not set the `U_` value. Registry storage is
separate from `DOCKER_STORAGE_MB`, which accounts for Compose definitions,
revisions, retained binds, and measurable managed volumes.

Use an SSH public key for the tenant account, pin the SSH host key, and confirm
the live broker entitlement:

```bash
set -Eeuo pipefail
set +x

APP_OWNER='APP_OWNER'
APP_PROJECT='APP_PROJECT'
IMAGE_NAME='IMAGE_NAME'
RELEASE_TAG='RELEASE_TAG'

# DEVELOPMENT-ONLY target. Production remains deferred.
VESTA_HOST='dev.jackpridham.com'

[[ "$APP_OWNER" != APP_OWNER && "$APP_OWNER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
[[ "$APP_PROJECT" != APP_PROJECT && "$APP_PROJECT" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
[[ "$IMAGE_NAME" != IMAGE_NAME && "$IMAGE_NAME" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]]
[[ "$RELEASE_TAG" != RELEASE_TAG && "$RELEASE_TAG" != latest ]]
[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
[[ "$VESTA_HOST" == 'dev.jackpridham.com' ]]

# Require explicit acknowledgement before the first network operation.
read -r -p \
  'Type DEVELOPMENT ONLY - PRODUCTION DEFERRED to continue: ' \
  deployment_acknowledgement
[[ "$deployment_acknowledgement" == 'DEVELOPMENT ONLY - PRODUCTION DEFERRED' ]]

SSH_TARGET="${APP_OWNER}@${VESTA_HOST}"
ssh -- "$SSH_TARGET" v-docker quota json | jq .
ssh -- "$SSH_TARGET" v-docker show "$APP_PROJECT" json \
  | jq -e --arg owner "$APP_OWNER" --arg project "$APP_PROJECT" \
    '.OWNER == $owner and .PROJECT == $project and .PROFILE == "standard"'
```

Do not solve an eligibility failure by adding the tenant to the Docker group,
changing socket permissions, granting broad sudo, or logging in as Debian.
The Vesta administrator owns account/package/shell onboarding and access
reconciliation.

## Credential and key-store model

Vesta separates provider recovery, routine provider integration, publication,
and runtime pull authority:

| Authority | Holder and purpose | Storage and disclosure |
| --- | --- | --- |
| Bootstrap administrator | Vesta root recovery authority used during controlled installation/recovery, not routine API work. | Generated by Vesta and retained only in protected root authority. Never given to a tenant. |
| Integration identity | Least-privilege Vesta identity for allowlisted Harbor project, quota, robot, and health operations. | Read from a protected root file or descriptor by the fixed adapter. Never argv, environment, output, HTML, logs, audit, or unencrypted backup. |
| Runtime pull identity | Distinct owner/project pull-only identity used by Vesta for preview-bound immutable pulls. | Vesta creates, validates, rotates, and atomically installs it in the protected owner registry store. It is never shown to the tenant and cannot push. |
| Publisher identity | Distinct owner/project push-and-pull identity used only by the maintainer's builder or CI. | The tenant generates the secret, sends it once on bounded stdin, and stores it only in a protected local credential store. Vesta does not persist or return it. It cannot administer Harbor or mutate Vesta. |

Provider authority is rooted at `/usr/local/vesta/data/harbor/`, a root-owned
mode-`0700` directory separate from tenant Compose state. Authority and secret
files are root-owned, regular, non-symlink, single-link mode-`0600` files;
secret material is separate from metadata. Harbor database and artifact data
is provider data, not a tenant project backup. Provider mode is exactly
`disabled` or `managed`.

Publisher and runtime credentials are not interchangeable. Rotation validates
the replacement before revoking the prior generation. Publisher disablement
blocks later pushes but leaves the runtime pull identity, artifacts, accepted
revisions, and running workloads intact. The generic `registry-change` and
`registry-delete` commands cannot replace or remove Vesta's provider-managed
runtime entry.

The tenant receives only the non-secret publisher username and repository
metadata from Vesta. The tenant chooses or replaces the publisher secret with
`registry-publisher-change`. The broker snapshots bounded stdin into protected
temporary storage; Vesta creates and validates the replacement publisher,
switches authority, revokes the prior generation, and destroys the snapshot.
For runtime pulls, Vesta injects its separate pull-only credential through the
protected owner Docker configuration only for the bounded registry operation;
the value is not exposed to the workload.

Secret bytes must travel only through stdin or protected files. They must never
appear in argv, exported or Compose environment, shell tracing, stdout/stderr,
JSON, HTML, process metadata, labels, logs, audit, Git, deployment artifacts,
or unencrypted backups. Non-secret fields such as `REGISTRY`, `REPOSITORY`, and
`PUBLISHER_USERNAME` may be read from `registry-info`.

The exact tenant lifecycle is:

```text
v-docker registry-info APP_PROJECT [json|plain]
v-docker registry-publisher-change < publisher-secret
v-docker registry-publisher-disable
```

`registry-info` returns redacted discovery and readiness only. Publisher change
accepts no arguments; publisher disable accepts no arguments. The authenticated
broker derives the owner, endpoint, namespace, identity, and permission set.

## Canonical release workflow after activation

Do not use this section until the status warning at the top has been replaced
by passing development acceptance and the Vesta administrator has confirmed
managed provider readiness.

### 1. Discover readiness and rotate the publisher safely

Continue in the validated shell from the eligibility section. First require
healthy, fresh managed-provider state. A previously disabled publisher is an
allowed starting state because this flow creates a replacement.

```bash
registry_json="$(
  ssh -- "$SSH_TARGET" v-docker registry-info "$APP_PROJECT" json
)"
printf '%s\n' "$registry_json" | jq .
jq -e '
  .MANAGED == true
  and (.STATE == "ready" or .STATE == "publisher-disabled")
  and .HEALTH == "healthy"
  and .FRESHNESS == "fresh"
  and (.QUOTA_MB == "unlimited" or .QUOTA_MB > 0)
' <<<"$registry_json" >/dev/null

REGISTRY="$(jq -er '.REGISTRY' <<<"$registry_json")"
REPOSITORY="$(jq -er '.REPOSITORY' <<<"$registry_json")"

docker_config_dir="${DOCKER_CONFIG:-$HOME/.docker}"
docker_config_file="${docker_config_dir}/config.json"
[[ -f "$docker_config_file" && ! -L "$docker_config_file" ]]
credential_helper="$(
  jq -er --arg registry "$REGISTRY" '
    (.credHelpers[$registry] // .credsStore // empty)
    | select(type == "string" and test("^[A-Za-z0-9._-]+$"))
    | select(length > 0)
  ' "$docker_config_file"
)"
helper_binary="docker-credential-${credential_helper}"
helper_path="$(command -v -- "$helper_binary")"
[[ "$helper_path" == /* && -f "$helper_path" && -x "$helper_path" ]]
jq -e --arg registry "$REGISTRY" '
  ((.auths[$registry].auth? // "") == "")
' "$docker_config_file" >/dev/null

umask 077
publisher_secret_file="$(mktemp)"
trap 'rm -f -- "$publisher_secret_file"' EXIT
openssl rand -base64 48 \
  | tr '+/' '-_' \
  | tr -d '=\n' >"$publisher_secret_file"
chmod 0600 "$publisher_secret_file"
[[ ! -L "$publisher_secret_file" ]]
[[ "$(wc -c <"$publisher_secret_file")" -ge 43 ]]
[[ "$(wc -c <"$publisher_secret_file")" -le 128 ]]

ssh -- "$SSH_TARGET" v-docker registry-publisher-change \
  <"$publisher_secret_file"

registry_json="$(
  ssh -- "$SSH_TARGET" v-docker registry-info "$APP_PROJECT" json
)"
jq -e '
  .STATE == "ready"
  and .PUBLISHER_ENABLED == true
  and (.PUBLISHER_USERNAME | type == "string" and length > 0)
' <<<"$registry_json" >/dev/null

PUBLISHER_USERNAME="$(jq -er '.PUBLISHER_USERNAME' <<<"$registry_json")"
docker login "$REGISTRY" \
  --username "$PUBLISHER_USERNAME" \
  --password-stdin <"$publisher_secret_file"
jq -e --arg registry "$REGISTRY" '
  ((.auths[$registry].auth? // "") == "")
' "$docker_config_file" >/dev/null
rm -f -- "$publisher_secret_file"
trap - EXIT
```

The maintainer supplies the secret; `PUBLISHER_USERNAME` is non-secret output
from Vesta. Configure Docker to use the workstation or CI platform's protected
credential helper. Without `credsStore` or a registry-specific `credHelpers`
entry, Docker may write a reversible base64 `auth` value to `config.json`; file
permissions do not turn that value into encryption. The block above therefore
fails before publisher rotation unless the selected helper is configured and
its `docker-credential-HELPER` binary is available, then verifies login did not
write inline auth. This guide does not offer a temporary isolated
`DOCKER_CONFIG` fallback: interruption or incomplete cleanup could leave that
base64 credential behind. Do not copy the secret into a command, environment
variable, CI log, repository file, or Compose file. Keep the temporary file
only until login completes and publisher rotation has succeeded.

If a publisher secret is lost, generate a new protected file and repeat
`registry-publisher-change`; Vesta never recovers or displays the old value.

### 2. Build locally, push a versioned tag, and resolve the digest

Build and test on the maintainer workstation or CI builder, not the managed
Vesta host. The tag is only a temporary publication name. The returned Harbor
repository and immutable digest become deployment input.

```bash
local_image="${IMAGE_NAME}:${RELEASE_TAG}"
published_tag="${REPOSITORY}:${RELEASE_TAG}"

docker build --pull --tag "$local_image" .
docker tag "$local_image" "$published_tag"
docker push "$published_tag"

IMAGE_DIGEST="$(
  docker buildx imagetools inspect "$published_tag" \
    --format '{{json .Manifest.Digest}}' \
    | jq -er 'select(type == "string" and test("^sha256:[a-f0-9]{64}$"))'
)"
IMAGE_REFERENCE="${REPOSITORY}@${IMAGE_DIGEST}"
printf '%s\n' "$IMAGE_REFERENCE"
```

The application-owned deploy adapter must render that exact
`REPOSITORY@IMAGE_DIGEST` value into the correct service image field in
`compose.yaml`. The generic Vesta guide cannot choose the service, Dockerfile,
build arguments, target platform, secrets, or readiness probe for an
application. Verify the rendered file locally before sending it:

```bash
mapfile -t compose_images < <(
  docker compose -f compose.yaml config --images
)
image_occurrences=0
for compose_image in "${compose_images[@]}"; do
  [[ "$compose_image" =~ @sha256:[a-f0-9]{64}$ ]]
  if [[ "$compose_image" == "$IMAGE_REFERENCE" ]]; then
    ((image_occurrences += 1))
  fi
done
[[ "$image_occurrences" -eq 1 ]]
```

Never deploy `RELEASE_TAG`, even if it currently resolves to the same digest.
Do not substitute an SCP/rsync transfer, `docker save` archive, `docker load`,
raw Docker pull, or a direct edit of Vesta desired state.

The current tenant command accepts one immutable image that occurs exactly
once in the protected candidate. For multiple distinct newly delivered images,
render each distinct digest exactly once and call `v-docker image-pull` once
per image with the same preview tuple before apply. If one new image appears in
multiple services, revise the definition or use the reviewed administrator
delivery path; the tenant command fails closed rather than widening pull
authority.

### 3. Preview, pull, apply, and verify

This recurring-release example updates an existing project. It uses the exact
server-issued preview tuple and the exact digest from Harbor.

```bash
before_json="$(
  ssh -- "$SSH_TARGET" v-docker show "$APP_PROJECT" json
)"
before_revision="$(
  jq -er --arg owner "$APP_OWNER" --arg project "$APP_PROJECT" '
    select(.OWNER == $owner and .PROJECT == $project)
    | select(.PROFILE == "standard")
    | .REVISION
    | select(. > 0)
  ' <<<"$before_json"
)"

preview_json="$(
  ssh -- "$SSH_TARGET" v-docker preview "$APP_PROJECT" change \
    < compose.yaml
)"
printf '%s\n' "$preview_json" | jq .
jq -e --arg owner "$APP_OWNER" --arg project "$APP_PROJECT" \
  --argjson revision "$before_revision" '
  .VALID == true
  and .OWNER == $owner
  and .PROJECT == $project
  and .PROFILE == "standard"
  and .MODE == "change"
  and .EXPECTED_CURRENT_REVISION == $revision
  and (.PREVIEW_ID | test("^[a-f0-9]{32}$"))
  and (.SOURCE_SHA256 | test("^[a-f0-9]{64}$"))
  and (.CANDIDATE_SHA256 | test("^[a-f0-9]{64}$"))
' <<<"$preview_json" >/dev/null

preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview_json")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview_json")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview_json")"
expected_revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview_json")"

ssh -- "$SSH_TARGET" v-docker image-pull \
  "$APP_PROJECT" "$preview_id" "$source_sha" "$candidate_sha" \
  "$expected_revision" "$IMAGE_REFERENCE"

# Run apply only after reviewing and approving preview_json unchanged.
ssh -- "$SSH_TARGET" v-docker apply \
  "$APP_PROJECT" "$preview_id" "$source_sha" "$candidate_sha" \
  "$expected_revision"

health_json="$(
  ssh -- "$SSH_TARGET" v-docker health "$APP_PROJECT" json
)"
operation_json="$(
  ssh -- "$SSH_TARGET" v-docker operation "$APP_PROJECT" json
)"
after_json="$(
  ssh -- "$SSH_TARGET" v-docker show "$APP_PROJECT" json
)"
drift_json="$(
  ssh -- "$SSH_TARGET" v-docker drift "$APP_PROJECT" json
)"

jq -e '.STATUS == "healthy"' <<<"$health_json" >/dev/null
jq -e '.RESULT == "succeeded"' <<<"$operation_json" >/dev/null
after_revision="$(jq -er '.REVISION' <<<"$after_json")"
jq -e --argjson before "$before_revision" '.REVISION > $before' \
  <<<"$after_json" >/dev/null
jq -e '.MATCH == true' <<<"$drift_json" >/dev/null

# Validate the exact v-docker show WORKLOAD contract before extraction.
jq -e '
  has("WORKLOAD")
  and (
    .WORKLOAD == null
    or (
      (.WORKLOAD | type) == "object"
      and (.WORKLOAD | has("PROBES"))
      and (.WORKLOAD.PROBES | type) == "array"
      and all(
        .WORKLOAD.PROBES[];
        type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")
      )
      and ((.WORKLOAD.PROBES | length)
        == (.WORKLOAD.PROBES | unique | length))
    )
  )
' <<<"$after_json" >/dev/null
mapfile -t probe_names < <(
  jq -r '
    if .WORKLOAD == null then empty else .WORKLOAD.PROBES[] end
  ' <<<"$after_json"
)
if ((${#probe_names[@]} > 0)); then
  # Branch A: run every immutable Vesta-managed readiness probe.
  for probe_name in "${probe_names[@]}"; do
    ssh -- "$SSH_TARGET" v-docker probe "$APP_PROJECT" "$probe_name" json \
      | jq -e '.STATE == "pass"' >/dev/null
  done
else
  # Branch B: run the app repository's no-argument development acceptance
  # wrapper. Replace only APP_ACCEPTANCE_COMMAND with its documented path.
  APP_ACCEPTANCE_COMMAND='APP_ACCEPTANCE_COMMAND'
  [[ "$APP_ACCEPTANCE_COMMAND" != APP_ACCEPTANCE_COMMAND ]]
  [[ "$APP_ACCEPTANCE_COMMAND" =~ ^[.]/[A-Za-z0-9_./-]{1,255}$ ]]
  app_acceptance_path="$(realpath -e -- "$APP_ACCEPTANCE_COMMAND")"
  [[ "$app_acceptance_path" == "$PWD"/* ]]
  [[ -f "$app_acceptance_path" && -x "$app_acceptance_path" ]]
  [[ ! -L "$APP_ACCEPTANCE_COMMAND" ]]
  "$app_acceptance_path"
fi

# Both readiness branches must reach the same non-mutating rollback check.
rollback_check_json="$(
  ssh -- "$SSH_TARGET" v-docker rollback-preview \
    "$APP_PROJECT" "$before_revision"
)"
jq -e --argjson current "$after_revision" \
  --argjson target "$before_revision" '
  .ACTION == "rollback"
  and .BOUND_CURRENT_REVISION == $current
  and .BOUND_TARGET_REVISION == $target
  and (.FROM_MANIFEST_SHA256 | test("^[a-f0-9]{64}$"))
  and (.TO_MANIFEST_SHA256 | test("^[a-f0-9]{64}$"))
' <<<"$rollback_check_json" >/dev/null
```

Readiness names and commands come only from the application's immutable
workload manifest; the caller supplies no probe command or arguments. Under
the actual command contract, `WORKLOAD` belongs to `v-docker show` output, not
`registry-info` or `health`; those results are checked separately above. If
the verified project has workload metadata, `v-docker show` returns `WORKLOAD`
as an object and `PROBES` as its array of probe names. Without verified
workload metadata, the command returns `WORKLOAD: null`. A missing `WORKLOAD`
key, any other `WORKLOAD` type, a missing or non-array `PROBES`, duplicate
names, or a name outside the broker's lowercase probe-name contract stops
before branch selection. There is no optional `[]?` extraction that could
turn malformed data into the no-probe path.

If the validated project has probes, every declared probe must pass. If the
validated result is `WORKLOAD: null` or has an empty probe array, the
application repository must document a no-argument, development-only
acceptance wrapper; replace the one `APP_ACCEPTANCE_COMMAND` placeholder with
that relative executable path. The guard resolves it beneath the current
repository, rejects a symlink or non-executable, and invokes it directly
without `eval`. That wrapper owns its application-specific checks, must return
nonzero on failure, and must not print secrets. Health, successful operation,
forward revision, matching drift, and a manifest-bound rollback preview are
mandatory before either branch is accepted.

If apply or health fails, Vesta follows the existing convergence and rollback
transaction. Publication does not alter the running revision, and a failed
candidate does not make its tag authoritative.

`apply` performs the locked deployment of the approved candidate. The separate
`v-docker deploy APP_PROJECT` lifecycle command only reconverges the already
accepted current revision; it is not a shortcut around preview, immutable
image pull, or apply. Use it only when the accepted revision needs explicit
runtime reconvergence:

```bash
ssh -- "$SSH_TARGET" v-docker deploy "$APP_PROJECT"
```

### 4. Revoke publisher access after publication

After push and deployment evidence are complete, revoke the publisher and
remove its local login. Runtime pulls continue through Vesta's separate
pull-only identity.

```bash
ssh -- "$SSH_TARGET" v-docker registry-publisher-disable
docker logout "$REGISTRY"

ssh -- "$SSH_TARGET" v-docker registry-info "$APP_PROJECT" json \
  | jq -e '
      .STATE == "publisher-disabled"
      and .PUBLISHER_ENABLED == false
    ' >/dev/null
```

Disabling publication does not delete the tag, digest, Harbor project,
accepted Vesta revision, local runtime image, container, route, bind, volume,
or backup.

## Revision rollback

Rollback is a Vesta revision transaction, not a Harbor tag change. Review the
manifest-bound preview and apply only its exact fields. This example selects
the newest retained revision older than the current one and still requires an
explicit confirmation.

```bash
current_json="$(
  ssh -- "$SSH_TARGET" v-docker show "$APP_PROJECT" json
)"
target_revision="$(
  jq -er '
    .REVISION as $current
    | [.REVISIONS[] | select(. < $current)]
    | max
  ' <<<"$current_json"
)"
rollback_json="$(
  ssh -- "$SSH_TARGET" v-docker rollback-preview \
    "$APP_PROJECT" "$target_revision"
)"
printf '%s\n' "$rollback_json" | jq .

read -r -p 'Type rollback to apply this exact preview: ' confirmation
[[ "$confirmation" == rollback ]]

bound_current="$(jq -er '.BOUND_CURRENT_REVISION' <<<"$rollback_json")"
bound_target="$(jq -er '.BOUND_TARGET_REVISION' <<<"$rollback_json")"
from_manifest="$(jq -er '.FROM_MANIFEST_SHA256' <<<"$rollback_json")"
to_manifest="$(jq -er '.TO_MANIFEST_SHA256' <<<"$rollback_json")"

ssh -- "$SSH_TARGET" v-docker rollback-apply \
  "$APP_PROJECT" "$bound_target" "$bound_current" \
  "$from_manifest" "$to_manifest"
ssh -- "$SSH_TARGET" v-docker health "$APP_PROJECT" json | jq .
ssh -- "$SSH_TARGET" v-docker drift "$APP_PROJECT" json \
  | jq -e '.MATCH == true' >/dev/null
```

Definition rollback retains persistent bind and volume data. Use managed
backup/restore for application-data recovery.

## Lifecycle and failure behavior

- **Lost publisher secret:** Vesta cannot reveal it. Generate a replacement in
  a protected file and run `registry-publisher-change`; the old generation is
  revoked only after the replacement validates.
- **Explicit disable:** `registry-publisher-disable` revokes pushes. A later
  publishing session requires a new secret through
  `registry-publisher-change`.
- **Quota downgrade:** a reduction below observed usage fails before the
  package or Harbor quota changes. Setting `DOCKER_REGISTRY_MB=0` removes
  publishing eligibility without deleting artifacts or stopping workloads.
- **Suspension or eligibility loss:** suspension, administrator conversion,
  loss of interactive shell/package eligibility, or zero Docker entitlement
  revokes publisher access. Runtime authority and retained artifacts follow
  Vesta's protected retained-state policy.
- **Provider outage:** discovery, new pushes, provisioning, rotation, and
  missing-image pulls fail closed or remain pending. Vesta does not change
  Compose, routes, firewall, DNS, or a running workload as fallback.
- **Provider disable or restore:** these are administrator operations. Vesta
  owns dependency planning, encrypted provider backup, validation, ingress,
  health, revocation, retention, and recovery. Tenants cannot pass an archive
  or invoke Harbor administration.

## Responsibilities

| Party | Owns | Does not own |
| --- | --- | --- |
| Vesta administrator | Install/disable/restore decisions; provider mode and pinned release; shared TLS ingress; package entitlement and quota; account/shell onboarding; provider health, backup, retention, and privileged provider operations. | Application source, Dockerfile, release content, application secrets, or app acceptance logic. |
| Tenant maintainer | Tenant SSH key; protected publisher credential store; external build/test/push; digest resolution; immutable preview review; apply approval; release health/readiness/drift evidence; publisher revocation. | Harbor administration, another owner, runtime pull credential, raw Docker on Vesta, Debian sudo, or privileged profiles. |
| Vesta-managed Harbor | Private OCI manifests/layers, project isolation, registry authentication enforcement, and measured registry usage. | Vesta desired state, workload deployment, routes, revisions, rollback, or production authorization. |
| Application repository | Source, Dockerfile, Compose/template, non-secret environment configuration, managed-secret declarations, build tests, deploy adapter, app-specific readiness/acceptance, and production deferral policy. | Provider lifecycle, shared ingress, tenant package authority, Vesta runtime credential, or Harbor administrator access. |

## Troubleshooting

### Zero entitlement or broker denial

Confirm both effective `DOCKER_PROJECTS` and `DOCKER_REGISTRY_MB` are positive
or `unlimited`, the account is unsuspended and non-administrator, Bash is the
interactive shell, SSH is the tenant account, and the existing project profile
is `standard`. The Vesta administrator repairs package/shell reconciliation;
do not request Docker group, socket, broad sudo, or Debian access.

### Publisher disabled, rejected, or expired

Run `registry-info`. When the provider is healthy and fresh, generate a new
protected secret and use `registry-publisher-change`, then read the current
`PUBLISHER_USERNAME` again. Never reuse a secret from logs, ask Vesta to reveal
one, or use the bootstrap administrator.

### Push denied

Verify the exact `REGISTRY`, `REPOSITORY`, and `PUBLISHER_USERNAME` returned
after rotation; confirm Docker login used password stdin; and push only to the
returned owner repository. The publisher cannot create projects, change quota,
delete the Harbor project, or access another namespace.

### Quota exceeded

Compare `USED_MB` and `QUOTA_MB` in `registry-info` and the corresponding
`U_DOCKER_REGISTRY_MB`/`DOCKER_REGISTRY_MB` Vesta values. Removing or retaining
artifacts is an administrator policy decision; do not bypass quota with an
archive or another namespace.

### Registry unavailable or stale

Stop before push, rotation, preview-bound pull, or apply. Existing running
containers should remain unchanged. An administrator checks provider health,
storage, certificate, operation backlog, ingress, and backup state. There is no
raw-Docker or archive fallback.

### TLS or hostname failure

Use the Vesta hostname and panel port returned by `registry-info`; do not use a
raw IP, invent a registry DNS record, bypass certificate validation, or expose
a Harbor port. DNS, the Vesta certificate, and shared listener are
administrator-owned.

### Mutable tag appears in Compose

Replace it with the exact `REPOSITORY@IMAGE_DIGEST` resolved after push and
create a new preview. Do not edit preview fields or treat Docker `RepoDigests`
alone as Vesta admission evidence.

### A script attempts raw Docker, SCP/rsync, or an image archive

Stop the script. Local Docker is for external build/test/push only. Tenant
delivery uses SSH plus `v-docker`; Compose goes to preview on stdin, and images
come from the preview-bound immutable registry pull. SCP/rsync is reserved for
reviewed non-secret application data in an already-created managed bind leaf,
not source release, Compose authority, credentials, archives, or Docker state.

### Production deployment requested

Production remains deferred. A development build, Harbor push, preview, or
acceptance result does not authorize production. The application adapter must
return before any production SSH connection or `v-docker` operation until a
separate authorization names the production target, immutable release,
workload mutation, approval, and rollback/continuity scope.

### Current Harbor v2.15.0 robot-secret blocker

This is the present product blocker, not tenant misconfiguration. Harbor
v2.15.0 generates the robot creation secret and does not let the approved
least-privilege integration identity set or refresh the caller-selected
publisher secret. Using routine bootstrap-administrator access or returning a
server-generated secret would violate the approved contract. The boundary was
not weakened; the provider was rolled back to stable disabled state. See the
[acceptance evidence](../validation/2026-08-08-vesta-managed-harbor-development.md)
for the redacted proof and exact deferred next action.

## Related documentation

- [Complete source-to-Vesta deployment runbook](../../DOCKER_ORCHESTRATION_DEPLOYMENT.md)
- [Container-orchestration operator guide](../../docs/container-orchestration.md)
- [Harbor provider contract](../contracts/harbor-provider.md)
- [Compose tenant shell-access contract](../contracts/compose-shell-access.md)
- [Compose self-service deployment contract](../contracts/compose-self-service-deployment.md)
- [Compose project probe contract](../contracts/compose-project-probes.md)
