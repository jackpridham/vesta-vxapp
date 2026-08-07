# Docker Orchestration Deployment - vesta-vxapp | Vortex Enterprises

This runbook explains how an ordinary Vesta account such as
`asterisk-vxapp` or `slave-vxapp` can deploy and operate its own Docker
Compose projects through vesta-vxapp. It covers the complete path from account
entitlement and SSH access through image delivery, Compose preview/apply,
routes, data, operations, backup, and recovery.

> **Important:** a Unix/Vesta user may literally be named `slave-vxapp`, but
> that does not grant the privileged Compose profile also named
> `slave-vxapp`. Every tenant SSH command is forced to the owner-equal
> `standard` profile. Privileged profiles and production workload changes are
> administrator-only.

## 1. The deployment model

Vesta is the control plane. Docker is the runtime.

- Vesta owns identity, authorization, policy, quotas, desired state, routes,
  secrets, registry credentials, revisions, backup, health, and audit.
- The tenant uses `/usr/local/bin/v-docker`; it does not use `docker`,
  `docker compose`, the Docker socket, or the Docker group.
- The tenant can manage only its own `standard` projects. The broker derives
  the owner from the SSH login and accepts no owner, actor, or profile flag.
- Compose input is sent on bounded standard input. The broker never opens a
  tenant-selected file as root.
- The canonical definition is root-owned at
  `/usr/local/vesta/data/users/<user>/docker-projects/<project>/compose.yaml`.
  Do not copy files into or edit that control directory.
- The runtime Compose project name is `vx-<user>-<project>`.
- Persistent bind data is constrained to
  `/home/<user>/docker/<project>/binds/<name>/`.

There is no special Compose file-transfer protocol. SSH carries the Compose
bytes to `v-docker preview` on stdin. `scp` or `rsync` is useful only for
application data that intentionally belongs in a managed bind directory.

## 2. One-time operator preparation

The following commands are run by the Vesta server administrator, not by the
tenant.

### 2.1 Install Docker orchestration and shell access

Install the repository release through the normal vesta-vxapp release process,
then install or repair the shell-access boundary:

```bash
sudo /usr/local/vesta/bin/v-install-docker-service
sudo /usr/local/vesta/bin/v-install-docker-shell-access
sudo /usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users
```

The shell-access installer creates and validates:

- the derived `vesta-compose-users` group;
- the exact sudo policy for `v-run-user-docker-command`;
- `/usr/local/bin/v-docker`; and
- current eligible group membership.

It does not grant Docker group or socket access.

### 2.2 Make the account eligible

An eligible tenant must be all of the following:

- a real Unix account and matching Vesta account;
- non-administrator, unsuspended, and not `root` or `admin`;
- configured with an interactive Bash login shell;
- assigned a package whose effective `DOCKER_PROJECTS` is a positive integer
  or `unlimited`; and
- within the package's service, CPU, memory, PID, storage, port, secret, and
  volume limits.

Set these through the Vesta package and user interfaces. Do not manually edit
`user.conf` or `/etc/group`. Normal user/package/shell lifecycle commands
reconcile membership automatically. An operator can repair one account or all
accounts explicitly:

```bash
sudo /usr/local/vesta/bin/v-sync-docker-shell-access asterisk-vxapp
sudo /usr/local/vesta/bin/v-sync-docker-shell-access slave-vxapp
sudo /usr/local/vesta/bin/v-sync-docker-shell-access-all
```

Verify the installation without granting broader sudo:

```bash
getent group vesta-compose-users
sudo -l -U asterisk-vxapp
sudo -l -U slave-vxapp
```

The only Compose privilege shown for an eligible user should be the exact
broker. Package entitlement, suspension, shell, account identity, and group
membership are rechecked on every call. A fresh login may be needed before an
interactive shell displays changed supplementary groups, but live broker
authorization changes immediately.

### 2.3 Configure SSH safely

Use an ordinary SSH public key for the tenant account. For example, from the
operator workstation:

```bash
ssh-copy-id asterisk-vxapp@vesta.example.com
ssh asterisk-vxapp@vesta.example.com /usr/local/bin/v-docker quota json
```

For automation, provision a dedicated deployment key, restrict possession of
the private key to the CI secret store, and pin the server host key in a
managed `known_hosts` file. Do not use `StrictHostKeyChecking=no`, share an
administrator key, or expose the Vesta/Docker socket over SSH.

## 3. Tenant preflight

Log in as the tenant itself:

```bash
ssh asterisk-vxapp@vesta.example.com
command -v v-docker
v-docker quota json | jq .
v-docker projects json | jq .
```

The same flow works for a user named `slave-vxapp`:

```bash
ssh slave-vxapp@vesta.example.com
v-docker quota json | jq .
```

Do not run `sudo v-*` commands directly. `v-docker` invokes the one permitted
broker and derives identity from the kernel/sudo state.

Project names must match `[a-z0-9][a-z0-9-]{0,62}`. The examples below use
project `app`.

## 4. Build and deliver the image

Builds on the managed Vesta host are rejected. In particular, tenant projects
cannot use Compose `build:` and tenants cannot run `docker build`, `docker
pull`, `docker load`, or `docker compose`.

Use this supply chain instead:

1. Build and test the image on a developer builder or CI runner.
2. Push it to an approved public or private registry.
3. Resolve the pushed image to an immutable repository digest.
4. Have the administrator/trusted-delivery process pull, verify, and approve
   the exact image identity for this owner and installed policy/profile
   version where required.
5. Put the immutable reference in Compose, for example
   `registry.example.com/team/app@sha256:<64-hex-digest>`.

A tag such as `latest` may identify build intent, but it is not deployment
authority. Accepted revisions and rollback evidence bind exact image identity.
Image pull, archive load, local-image approval, trust-policy administration,
and migration remain operator-only operations.

For an image pulled by immutable registry digest, the operator uses the
owner-scoped pull and trust interfaces:

```bash
sudo /usr/local/vesta/bin/v-pull-docker-image \
  asterisk-vxapp \
  registry.example.com/team/app@sha256:DIGEST
sudo /usr/local/vesta/bin/v-verify-docker-image-trust \
  asterisk-vxapp \
  registry.example.com/team/app@sha256:DIGEST \
  standard json
```

The trust result, not a successful pull by itself, decides whether policy
accepts the image. If delivery is an offline local archive instead, the
operator stages a root-owned mode-0600 archive and matching checksum in the
approved protected staging directory, then uses:

```text
v-load-docker-image USER ARCHIVE CHECKSUM
v-approve-docker-image ACTOR USER IMAGE_REFERENCE IMAGE_ID OS ARCHITECTURE \
  PROFILE PROFILE_VERSION EXPIRES
```

The operator must take `IMAGE_ID`, operating system, and architecture from the
post-load inspection and use the installed `standard` profile version and a
valid expiry. Local approval binds that exact local identity; it does not waive
registry trust when the selected trust mode requires registry evidence. Do not
invent any of these values or approve a mutable tag as identity.

### Private registry login

The tenant may install an owner-scoped registry credential through bounded
stdin. The registry is a hostname accepted by the tenant broker, such as
`ghcr.io` or `registry.example.com`:

```bash
printf '%s' "$REGISTRY_TOKEN" \
  | v-docker registry-add registry.example.com deploy-user
v-docker registries json | jq .
```

Rotate or remove it with:

```bash
printf '%s' "$NEW_REGISTRY_TOKEN" \
  | v-docker registry-change registry.example.com deploy-user
v-docker registry-delete registry.example.com
```

Never put a registry password in argv, Compose, logs, labels, environment
metadata, or an unencrypted artifact. `v-docker registries` returns redacted
metadata only. If an image is still rejected after login, the operator must
resolve image trust/approval; registry authentication alone is not approval.

## 5. Prepare a policy-compliant Compose file

The exact policy is profile/version bound, but a `standard` project must at
least follow these boundaries:

- use immutable digest images and no `build:`;
- declare bounded CPU, memory, and PID resources for every service;
- use bridge networking only;
- use explicit allowed host IPs for published ports;
- use only managed bind roots and managed named volumes;
- never request privileged mode, host PID/IPC/network, devices, unsafe
  capabilities, Docker/containerd sockets, arbitrary host paths, external
  networks, custom security options, or anonymous volumes; and
- keep passwords, private keys, tokens, and other secret-like values out of
  Compose environment, command, labels, health checks, URLs, and annotations.

Example shape (replace the digest and resource values with approved values):

```yaml
services:
  web:
    image: registry.example.com/team/app@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 512M
          pids: 256
    ports:
      - target: 8080
        published: "18080"
        host_ip: 127.0.0.1
        protocol: tcp
    volumes:
      - type: bind
        source: /home/asterisk-vxapp/docker/app/binds/config
        target: /app/config
        read_only: true
        bind:
          create_host_path: false
```

The exact managed bind leaf must exist before deployment; automatic host-path
creation is rejected. The current tenant catalog has no bind-create operation,
and the authority-owned `binds` parent is intentionally not tenant-writable.
For a new advanced project, the operator must review the requested direct leaf
and prepare it through the shipped no-follow managed-directory helper before
the first preview:

```bash
sudo /usr/bin/perl \
  /usr/local/vesta/func/vx/compose/managed-directory.pl \
  asterisk-vxapp /home app config normal
sudo stat -c '%U:%G %a %n' \
  /home/asterisk-vxapp/docker/app/binds/config
```

The authority-owned traversal is mode `0750`; the direct `config` leaf becomes
tenant-owned mode `0750`. The helper validates every component without
following symlinks and establishes the owner-root mount guard. Do not replace
it with recursive `mkdir`, `chown`, or a path supplied by the tenant. Bind
sources must be direct children such as `binds/config`, not nested arbitrary
host paths. Repeat the reviewed helper call for each required leaf.

Do not copy this file into Vesta's protected desired-state directory. Keep it
in the application repository and send it to preview over SSH.

## 6. Create or update through SSH preview/apply

Preview is read-only. It canonicalizes and validates the submitted bytes,
checks policy and quota, and returns a root-owned candidate with a 15-minute
lifetime. Apply must use the exact server-returned preview ID, source digest,
candidate digest, and expected revision.

### 6.1 Interactive create

From the developer workstation, stream the local file over SSH:

```bash
preview_json="$(
  ssh asterisk-vxapp@vesta.example.com \
    '/usr/local/bin/v-docker preview app add' < compose.yaml
)"
printf '%s\n' "$preview_json" | jq .
```

Review at least `VALID`, `PROFILE`, `MODE`, services, routes, quota impact,
digests, expected revision, and expiry. For add, the expected revision is `0`.

Extract fields without `eval` and apply:

```bash
preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview_json")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview_json")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview_json")"
revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview_json")"

ssh asterisk-vxapp@vesta.example.com \
  "/usr/local/bin/v-docker apply app $preview_id $source_sha $candidate_sha $revision"
```

### 6.2 Interactive update

Change only the mode:

```bash
preview_json="$(
  ssh asterisk-vxapp@vesta.example.com \
    '/usr/local/bin/v-docker preview app change' < compose.yaml
)"
printf '%s\n' "$preview_json" | jq .
```

Then extract and apply the four returned values exactly as above. For change,
`EXPECTED_CURRENT_REVISION` is the current positive revision. If another
deployment wins the race, policy changes, entitlement changes, or the preview
expires, apply fails closed; run preview again rather than editing any digest
or revision.

Apply holds the project lock through definition installation, runtime
convergence, health and route checks, and rollback. A failed candidate is
rolled back to the prior healthy definition/runtime where possible. Persistent
application data is not rewound by definition rollback.

### 6.3 Reusable deployment script

The following CI-friendly script avoids shell evaluation, validates the local
parameters, verifies the server response, and uses the same SSH channel for
both stages:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

: "${VESTA_SSH_TARGET:?set user@host}"
: "${VESTA_OWNER:?set expected Vesta/Unix owner}"
: "${VESTA_PROJECT:?set project}"
: "${VESTA_MODE:?set add or change}"
VESTA_APPLY="${VESTA_APPLY:-no}"
VESTA_APPROVED_PREVIEW="${VESTA_APPROVED_PREVIEW:-}"
compose_file="${1:-compose.yaml}"

[[ "$VESTA_OWNER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
[[ "$VESTA_PROJECT" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
[[ "$VESTA_MODE" == add || "$VESTA_MODE" == change ]]
[[ "$VESTA_APPLY" == yes || "$VESTA_APPLY" == no ]]

if [[ -n "$VESTA_APPROVED_PREVIEW" ]]; then
  [[ -f "$VESTA_APPROVED_PREVIEW" && ! -L "$VESTA_APPROVED_PREVIEW" ]]
  preview_json="$(<"$VESTA_APPROVED_PREVIEW")"
else
  [[ -f "$compose_file" && ! -L "$compose_file" ]]
  [[ "$(stat -c '%s' "$compose_file")" -le 1048576 ]]
  preview_json="$(
    ssh -- "$VESTA_SSH_TARGET" \
      "/usr/local/bin/v-docker preview $VESTA_PROJECT $VESTA_MODE" \
      < "$compose_file"
  )"
fi

jq -e \
  --arg owner "$VESTA_OWNER" \
  --arg project "$VESTA_PROJECT" \
  --arg mode "$VESTA_MODE" \
  '.VALID == true and .OWNER == $owner and .PROJECT == $project
   and .PROFILE == "standard"
   and .MODE == $mode
   and (.PREVIEW_ID | test("^[a-f0-9]{32}$"))
   and (.SOURCE_SHA256 | test("^[a-f0-9]{64}$"))
   and (.CANDIDATE_SHA256 | test("^[a-f0-9]{64}$"))
   and (.EXPECTED_CURRENT_REVISION | type == "number")
   and (if $mode == "add"
        then .EXPECTED_CURRENT_REVISION == 0
        else .EXPECTED_CURRENT_REVISION > 0
        end)' \
  <<<"$preview_json" >/dev/null

printf '%s\n' "$preview_json" | jq .

if [[ "$VESTA_APPLY" != yes ]]; then
  printf '%s\n' \
    'Preview only. Save stdout as mode 0600, review it, then rerun with' \
    'VESTA_APPLY=yes and VESTA_APPROVED_PREVIEW=<that-file>.' >&2
  exit 0
fi

[[ -n "$VESTA_APPROVED_PREVIEW" ]] || {
  printf '%s\n' 'Refusing apply without an approved preview file.' >&2
  exit 1
}

preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview_json")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview_json")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview_json")"
revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview_json")"

ssh -- "$VESTA_SSH_TARGET" \
  "/usr/local/bin/v-docker apply $VESTA_PROJECT $preview_id $source_sha $candidate_sha $revision"

ssh -- "$VESTA_SSH_TARGET" \
  "/usr/local/bin/v-docker health $VESTA_PROJECT json"
ssh -- "$VESTA_SSH_TARGET" \
  "/usr/local/bin/v-docker drift $VESTA_PROJECT json"
```

Keep production promotion as a separate, authorized pipeline stage. A passing
build or staging deployment does not authorize a production workload change.
Set `VESTA_OWNER` independently of `VESTA_SSH_TARGET`; checking the returned
owner prevents an otherwise valid key/host misconfiguration from applying to
the wrong tenant. The preview job should redirect stdout to a protected
mode-0600 artifact. A later approval job sets `VESTA_APPLY=yes` and
`VESTA_APPROVED_PREVIEW` to that reviewed artifact. The apply job validates and
uses those exact server-issued bytes; it does not create a replacement preview.
It must run before the 15-minute expiry.

## 7. SCP, rsync, and managed bind data

Do not use `scp`/`rsync` for Compose control state, secrets, registry
credentials, image archives, or Docker storage. For those inputs, use the
documented Vesta interfaces.

It is valid to transfer non-secret application content to an already-created,
tenant-owned managed bind leaf. For example:

```bash
rsync -a -- ./public/ \
  asterisk-vxapp@vesta.example.com:/home/asterisk-vxapp/docker/app/binds/public/
```

or:

```bash
scp -- ./config/defaults.json \
  asterisk-vxapp@vesta.example.com:/home/asterisk-vxapp/docker/app/binds/config/
```

Guidelines:

- transfer only beneath this user's exact project bind root;
- do not use `rsync --delete` casually, follow symlinks, or upload device/FIFO
  nodes;
- do not put secrets in transferred files unless a separately reviewed
  application-data design explicitly requires and protects them;
- back up important bind data before replacement; and
- prefer immutable image contents for application releases. Use bind transfer
  for durable/configurable data, not as an ad hoc substitute for an image
  build.

Vesta resolves bind paths without symlinks and rejects escapes, another user's
home, and arbitrary host paths. Named volumes are created as
`vx_<user>_<project>_<volume>` and remain Vesta-managed.

## 8. Secrets

Secret values travel only on bounded stdin:

```bash
printf '%s' "$DATABASE_PASSWORD" | v-docker secret-add app database-password
printf '%s' "$ROTATED_PASSWORD" | v-docker secret-change app database-password
v-docker secrets app json | jq .
v-docker secret-delete app database-password
```

Deletion is refused while the current revision references the secret. Listings
show redacted metadata, never values. Do not store secret values in Compose,
CI logs, shell tracing, argv, repository files, routes, health checks, or
unencrypted backups.

Creating a brand-new secret-dependent workload may require the protected
administrator workload-bundle flow because an add manifest that declares
managed secrets must be installed atomically with its protected secrets
directory. The tenant preview command intentionally does not accept a
filesystem path or secret bundle.

For that bootstrap, the application supplies a deterministic schema-1 bundle:
one gzip-compressed POSIX ustar archive containing exactly `compose.yaml`,
`manifest.sha256`, and `workload.json` in the contract's required order and
format, plus a separate checksum file. The operator copies both into a
root-owned mode-0700 directory matching
`/tmp/vx-compose-bundle.<6-to-64-A-Za-z0-9_-characters>/` (or `/var/tmp` with
the same basename) as mode `0600`.
A sibling `secrets/` directory is root-owned mode `0700` and contains exactly
one root-owned, regular, non-symlink mode-`0600` file per declared secret,
named for that secret, with no extra entries.

After independently checking the bundle producer and protected staging shape,
the operator runs:

```bash
sudo /usr/local/vesta/bin/v-plan-docker-workload-bundle \
  admin asterisk-vxapp app \
  /tmp/vx-compose-bundle.STAGING_ID/bundle.tar.gz \
  /tmp/vx-compose-bundle.STAGING_ID/bundle.sha256 \
  add json

sudo /usr/local/vesta/bin/v-import-docker-workload-bundle \
  admin asterisk-vxapp app \
  /tmp/vx-compose-bundle.STAGING_ID/bundle.tar.gz \
  /tmp/vx-compose-bundle.STAGING_ID/bundle.sha256 \
  add 0 \
  /tmp/vx-compose-bundle.STAGING_ID/secrets
```

`STAGING_ID` means the same actual 6-to-64-character allowed identifier in all
three paths, not the literal text. Planning is non-mutating. Import
revalidates the archive, checksum, local image approval, profile, policy,
quota, expected revision `0`, and secret directory under the project lock.
The caller must securely remove only that exact validated staging directory
after success or failure. Full deterministic archive and manifest requirements
are normative in
[`compose-workload-bundles.md`](.docs/contracts/compose-workload-bundles.md);
do not substitute a normal `tar` invocation. Later owner-scoped rotations use
`v-docker secret-change`.

## 9. Routes and ports

Compose port publication and Vesta HTTP routing are separate.

- A published port must use an explicit policy-approved host IP and pass
  conflict checks.
- HTTP routes are Vesta-owned metadata; Compose labels cannot create them.
- The domain must already belong to the same Vesta owner.
- The route selects a project service and its container port.
- That service/container-port pair must resolve to exactly one
  localhost-published TCP endpoint; missing, UDP, public-only, or ambiguous
  mappings fail closed.
- Projects without routes do not cause nginx route rendering.

For a service `web` listening on container port `8080`:

```bash
v-docker route-add app app.example.com web 8080 http /
v-docker deploy app
v-docker routes app json | jq .
v-docker route-delete app app.example.com
v-docker deploy app
```

Route add/delete stages candidate metadata; the following start-like `deploy`
converges it. Route convergence validates candidate health, nginx
configuration/reload, and a bounded local probe. Do not add automatic firewall
changes to a deployment script.

## 10. Operate and inspect the project

Common read operations:

```bash
v-docker projects json
v-docker show app json
v-docker definition app plain
v-docker validate app json
v-docker health app json
v-docker logs app web 200
v-docker stats app 5m json
v-docker alerts app json
v-docker operation app json
v-docker routes app json
v-docker backups app json
v-docker secrets app json
v-docker drift app json
v-docker probe app readiness json
```

`probe` accepts a persisted probe name, not arbitrary command text. Service,
argv, timeout, and output bounds come from the immutable workload manifest.

Lifecycle operations:

```bash
v-docker start app
v-docker stop app
v-docker restart app
v-docker recreate app
v-docker recreate app web
v-docker deploy app
```

Logs and JSON are bounded and redacted. They do not expose raw Docker config,
registry auth, secret values, unredacted Compose, or the caller environment.

## 11. Backup, rollback, drift, and removal

### Backup and restore

```bash
v-docker backup app
v-docker backups app json | jq .
v-docker restore app BACKUP_ID validate
v-docker restore app BACKUP_ID apply
```

Restore accepts only a managed backup ID. A tenant cannot pass an archive or
filesystem path. Unencrypted backups exclude secret values. Off-host
replication and encryption policy are administrator-controlled and must report
an explicit success state; absence is not success.

Tenant restore requires the project still to exist as the caller's `standard`
project. After `remove ... keep-data`, the broker no longer has project
authority to pass that check. Recovery then becomes an explicit operator
operation using the retained managed backup:

```bash
sudo /usr/local/vesta/bin/v-restore-docker-project \
  asterisk-vxapp app managed:BACKUP_ID validate
sudo /usr/local/vesta/bin/v-restore-docker-project \
  asterisk-vxapp app managed:BACKUP_ID apply
```

The operator must inspect and preserve retained bind/volume data before doing
this. If restore reports `restore-required`, re-provision every required
managed secret through the protected secret workflow (or, once a restored
`standard` project is eligible, through bounded `v-docker secret-add/change`),
then explicitly deploy and verify health. Never treat missing secret or
off-host recovery material as a successful restore.

### Definition rollback

First request immutable rollback evidence, then apply only the exact returned
revision/current revision/from-manifest/to-manifest values:

```bash
v-docker rollback-preview app REVISION
v-docker rollback-apply app REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA
```

Rollback changes desired/runtime definition. It does not rewind bind or volume
data; use backup/restore for application-data recovery.

### Drift reconciliation

```bash
v-docker drift app json | jq .
v-docker reconcile-preview app
v-docker reconcile-apply app DRIFT_SHA CURRENT_REVISION
```

Reconcile only from the current immutable observation. If evidence changes,
preview again.

### Removal

```bash
v-docker remove app keep-data
```

The tenant surface deliberately exposes retained-data removal only. There is
no tenant purge or global Docker prune. Managed bind data, named volumes, and
other retained data follow operator backup and retention policy.

## 12. Complete command catalog

Formats are `json` or `plain`; omitted formats default to redacted JSON.

```text
v-docker projects [json|plain]
v-docker show PROJECT [json|plain]
v-docker definition PROJECT [json|plain]
v-docker quota [json|plain]
v-docker validate PROJECT [json|plain]
v-docker health PROJECT [json|plain]
v-docker logs PROJECT [SERVICE] [LINES]
v-docker stats PROJECT [PERIOD] [json|plain]
v-docker alerts PROJECT [json|plain]
v-docker operation PROJECT [json|plain]
v-docker routes PROJECT [json|plain]
v-docker backups PROJECT [json|plain]
v-docker secrets PROJECT [json|plain]
v-docker registries [json|plain]
v-docker drift PROJECT [json|plain]
v-docker probe PROJECT PROBE [json|plain]
v-docker start PROJECT
v-docker stop PROJECT
v-docker restart PROJECT
v-docker recreate PROJECT [SERVICE]
v-docker deploy PROJECT
v-docker preview PROJECT add|change < compose.yaml
v-docker apply PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
v-docker backup PROJECT
v-docker restore PROJECT BACKUP_ID validate|apply
v-docker rollback-preview PROJECT REVISION
v-docker rollback-apply PROJECT REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA
v-docker reconcile-preview PROJECT
v-docker reconcile-apply PROJECT DRIFT_SHA CURRENT_REVISION
v-docker secret-add PROJECT NAME < secret-value
v-docker secret-change PROJECT NAME < secret-value
v-docker secret-delete PROJECT NAME
v-docker registry-add REGISTRY USERNAME < registry-password
v-docker registry-change REGISTRY USERNAME < registry-password
v-docker registry-delete REGISTRY
v-docker route-add PROJECT DOMAIN SERVICE PORT [SCHEME] [PATH]
v-docker route-delete PROJECT DOMAIN
v-docker alert-ack PROJECT ALERT
v-docker remove PROJECT keep-data
```

## 13. Troubleshooting

### `v-docker` is missing or sudo denies the broker

The operator should run:

```bash
sudo /usr/local/vesta/bin/v-install-docker-shell-access
sudo /usr/local/vesta/bin/v-sync-docker-shell-access USER
sudo /usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users
sudo -l -U USER
```

Then verify the account is unsuspended, uses Bash, is not an administrator,
and has effective `DOCKER_PROJECTS > 0` or `unlimited`. Do not solve this by
adding the tenant to the Docker group or broadening sudo.

### Preview rejects the Compose file

Read the bounded validation result. Common causes are mutable/untrusted images,
`build:`, missing service resource limits, quota exhaustion, implicit/unsafe
ports, forbidden capabilities or namespaces, host paths outside the managed
bind root, symlink escapes, anonymous/external volumes, and secret-like values
in Compose.

### Apply says preview is stale, expired, or mismatched

Do not reuse or modify old evidence. Run preview again and apply the new exact
ID, two digests, and expected revision.

### Private image cannot be deployed

Confirm the tenant registry metadata, then ask the operator to verify the
owner-scoped image pull/trust/approval evidence. A successful registry login
does not waive image policy.

### Container is healthy but the domain does not work

Check `v-docker routes app json`, confirm the domain belongs to this Vesta
owner, ensure the route targets the correct service/container port, and inspect
the bounded route/health operation result. Do not assume a Compose port or
label automatically creates nginx configuration.

### Deployment fails health checks

Inspect `health`, `logs`, `operation`, and `alerts`. Correct the image or
definition and submit a new `change` preview. Do not mutate containers with raw
Docker; that creates drift and bypasses desired-state authority.

## 14. Security and operational invariants

Never grant or automate any of the following for a tenant:

- Docker group/socket access or raw Docker/Compose;
- direct tenant sudo to existing `v-*` commands;
- caller-supplied owner, actor, or profile;
- `admin-approved` or privileged `slave-vxapp` profile selection;
- Docker sockets, privileged mode, host networking/PID/IPC, devices, unsafe
  capabilities, arbitrary host paths, or automatic bind creation;
- secret/registry values in argv, environment metadata, logs, UI, audit, or
  unencrypted backups;
- global prune, broad cleanup, or automatic firewall changes; or
- an automatic production promotion without explicit authorization naming the
  production target, release, and workload mutation.

The supported pipeline is therefore:

```text
developer/CI build and test
        -> push immutable image digest
        -> operator/trusted-delivery image verification
        -> SSH stdin Compose preview
        -> human or policy review of immutable preview evidence
        -> SSH apply with exact ID/digests/revision
        -> locked deploy, health, route convergence, or rollback
        -> health/drift/alerts/backup evidence
```

Further normative detail lives in
[`docs/container-orchestration.md`](docs/container-orchestration.md),
[`compose-shell-access.md`](.docs/contracts/compose-shell-access.md),
[`compose-self-service-deployment.md`](.docs/contracts/compose-self-service-deployment.md),
[`compose-policy.md`](.docs/contracts/compose-policy.md), and
[`compose-storage.md`](.docs/contracts/compose-storage.md).
