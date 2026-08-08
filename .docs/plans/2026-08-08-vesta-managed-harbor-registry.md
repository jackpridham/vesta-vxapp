# Vesta-Managed Harbor Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `$milestone-driven-implementation`. This is one integrated security product:
> provider authority, shared TLS ingress, Harbor API reconciliation, package
> entitlement, tenant credentials, recovery, and panel operations must agree
> before the tenant deployment path is usable. Use fresh implementers within
> each milestone, run focused tests continuously, and perform a security and
> specification review at every milestone boundary. Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** Make a pinned Harbor registry an optional Vesta-managed system
service so eligible Docker tenants can discover a private repository, publish
images, and deploy immutable digests through `v-docker` without external
registry setup or administrator involvement in ordinary releases.

**Architecture:** A root-owned Harbor provider layer under `func/vx/harbor/`
owns release verification, system-service lifecycle, exact shared-listener
ingress, API calls, tenant mapping, credentials, quota, observations, backup,
upgrade, and disable planning. Harbor has no host TCP listener and is reached
through a root/admin-gated local Unix socket behind the existing Vesta
hostname, panel TLS port, and certificate; Vesta remains the
only administration and deployment authority. Existing Compose registry and
preview/pull/apply helpers are extended with one protected provider-managed
entry, while Harbor remains outside every tenant Compose project.

**Tech Stack:** Bash, Vesta flat-file authority, Harbor v2.15.0 Docker Compose
distribution, Docker Compose v2, OCI Distribution HTTP API, Harbor REST API,
nginx, systemd, curl, jq, Cosign keyless bundle verification, age encryption,
PHP, JavaScript, focused Bash/PHP/Python fixtures, and the repository-owned
resource-limited production readiness launcher.

---

## Product milestones

1. Provider authority, release trust, and package quota exist in disabled mode
   without changing Docker, nginx, firewall, DNS, TLS, or tenant state.
2. A pinned Harbor system stack installs transactionally behind exact paths on
   Vesta's existing TLS listener and can be disabled without deleting data.
3. Eligible owners receive deterministic private projects, quota, separate
   runtime/publisher robots, protected registry state, and tenant discovery.
4. Provider health, lifecycle hooks, backup/restore, upgrade, disable planning,
   and panel operations are production-operable without workload mutation.
5. Contracts, operator/application guidance, focused suites, development-host
   acceptance, and the limited readiness gate close the release; production
   deployment remains explicitly deferred.

## Fixed interfaces and authority

The public administrator surface is exactly:

```text
v-install-harbor-registry
v-list-harbor-registry [json|plain]
v-list-harbor-registry-owners [json|plain]
v-sync-harbor-registry-owner USER
v-sync-harbor-registry-owners
v-update-harbor-registry
v-backup-harbor-registry
v-restore-harbor-registry BACKUP_ID validate|apply
v-plan-disable-harbor-registry [json|plain]
v-disable-harbor-registry CONFIRMATION_TOKEN
```

The owner-derived shell additions are exactly:

```text
v-docker registry-info PROJECT [json|plain]
v-docker registry-publisher-change < publisher-secret
v-docker registry-publisher-disable
```

No interface accepts a registry hostname, port, Harbor URL, provider version,
installer URL, owner for a tenant operation, Harbor project ID, permission
set, robot username, secret path, backup archive path, Docker option, or
workload mutation instruction.

Provider state uses this fixed layout:

```text
/usr/local/vesta/data/harbor/
  provider.json                 non-secret provider authority, mode 0600
  owners/<owner>.json           authoritative owner mapping, mode 0600
  observations/provider.json   bounded health/usage observation, mode 0600
  observations/<owner>.json    bounded quota/usage observation, mode 0600
  secrets/bootstrap.curl       recovery-only curl credential, mode 0600
  secrets/integration.curl     routine API curl credential, mode 0600
  secrets/backup.agekey        restore identity, mode 0600
  backup-recipient.txt         non-secret age recipient, mode 0600
  release/                     verified generated Harbor configuration
  backups/                     metadata only; ciphertext lives under BACKUP
  locks/provider.lock
/var/lib/vesta-harbor/          Harbor database, registry, job, and scanner data
/usr/local/vesta/nginx/conf/harbor-registry.conf
/etc/systemd/system/vesta-harbor.service
/run/vesta-harbor/proxy.sock   root:admin-gated local Harbor transport
```

The provider root and secret directory are root-owned mode `0700`. Authority,
secret, mapping, observation, and rendered configuration files are regular,
non-symlink, single-link, root-owned mode `0600`. Runtime composition always
uses project name `vesta-harbor`; no provider path is below
`data/users/<owner>/docker-projects`.

The initial fixed internal endpoints are:

```text
Harbor proxy/API: /run/vesta-harbor/proxy.sock
Harbor metrics:   /run/vesta-harbor/proxy.sock + /__vesta/metrics
Public registry: https://<authoritative Vesta FQDN>:<current panel TLS port>
```

Only exact `/v2/` and `/service/token` requests reach Harbor through the public
listener. The portal, `/api/`, metrics, and all other Harbor paths remain
local-only. This is the specification's loopback-only trust boundary realized
as a root-owned socket: an SSH tenant can connect to host loopback, so a
host-loopback Harbor TCP port would not enforce the no-raw-API requirement.

## Milestone 1: Disabled provider authority and package quota

### Task 1: Lock contracts, schemas, and focused test harness

**Files:**
- Create: `.docs/contracts/harbor-provider.md`
- Create: `test/harbor/fixtures/fake-harbor-api.py`
- Create: `test/harbor/fixtures/fake-docker.sh`
- Create: `test/harbor/fixtures/fake-systemctl.sh`
- Create: `test/harbor/lib.sh`
- Create: `test/harbor/run-focused.sh`
- Create: `test/harbor/test-state.sh`
- Modify: `.docs/README.md`

- [ ] **Step 1: Write the provider contract before implementation**

Record the fixed command catalog, filesystem layout, state machine, lock order,
JSON enums, endpoint derivation, no-side-channel rule, retention behavior, and
the separation between Harbor artifact storage and Vesta workload authority.
Include this lock order verbatim:

```text
provider shared/exclusive lock
  -> owner access lock
    -> owner registry lock
      -> tenant project lock (only after every Harbor API call has returned)
```

State that owner reconciliation never holds a tenant project lock while
calling Harbor and that existing Compose code retains its owner -> project ->
registry ordering inside workload transactions. Provider install, update,
backup, restore, and disable use the exclusive lock. Harbor-aware tenant,
package, and owner reconciliation paths take the shared provider lock before
the existing owner lock; ordinary Compose operations do not take a provider
lock.

- [ ] **Step 2: Add deterministic fixtures**

Make `fake-harbor-api.py` bind only a caller-selected loopback port, enforce
HTTP Basic authentication, retain projects/quotas/robots/artifacts in a JSON
state file, and implement only these pinned API routes:

```text
GET|PUT /api/v2.0/configurations
GET     /api/v2.0/health
GET|POST /api/v2.0/projects
GET|PUT /api/v2.0/projects/{name_or_id}
GET|PUT /api/v2.0/quotas/{id}
GET|POST /api/v2.0/robots
GET|PUT|DELETE /api/v2.0/robots/{id}
GET /api/v2.0/projects/{project}/repositories
GET /api/v2.0/projects/{project}/repositories/{repository}/artifacts/{reference}
GET /api/v2.0/systeminfo/volumes
GET /v2/
GET /service/token
```

Every other path returns `404`, requests over 1 MiB return `413`, malformed
JSON returns `400`, and the fixture log records method/path/status only. Make
the Docker and systemctl fixtures record bounded argv and model Compose
configuration/service state without invoking the host daemon.

- [ ] **Step 3: Add the focused runner**

Implement `test/harbor/run-focused.sh` as an explicit ordered list that runs
only `test/harbor/test-*.sh` plus Harbor PHP tests. It must use a fresh
temporary Vesta root per test and must not call ShellCheck or the full Compose
readiness suite.

- [ ] **Step 4: Run the first failing test**

Run:

```bash
bash test/harbor/test-state.sh
```

Expected: fail because `func/vx/harbor/main.sh` and provider state helpers do
not exist.

- [ ] **Step 5: Commit the contract and harness**

```bash
git add .docs/contracts/harbor-provider.md .docs/README.md test/harbor
git commit -m "test(harbor): define provider authority harness"
```

### Task 2: Implement provider state, validation, locking, and audit

**Files:**
- Create: `func/vx/harbor/main.sh`
- Create: `func/vx/harbor/common.sh`
- Create: `func/vx/harbor/audit.sh`
- Modify: `test/harbor/test-state.sh`

- [ ] **Step 1: Implement secure common primitives**

Define and use these signatures consistently:

```bash
vx_harbor_root
vx_harbor_data_root
vx_harbor_provider_prepare
vx_harbor_provider_mode
vx_harbor_provider_enabled
vx_harbor_provider_lock_acquire shared|exclusive
vx_harbor_provider_lock_release
vx_harbor_owner_state_path OWNER
vx_harbor_secure_regular_file PATH MODE
vx_harbor_json_write_atomic DESTINATION SOURCE
vx_harbor_origin_json
vx_harbor_audit OWNER OPERATION RESULT REASON
```

`vx_harbor_origin_json` must read the authoritative FQDN from Vesta state,
read exactly one numeric TLS listener from `$VESTA/nginx/conf/nginx.conf`, and
emit `{HOSTNAME,PORT,REGISTRY,ORIGIN}`. Reject localhost, IP literals,
single-label names, ports outside `1..65535`, multiple listener ports, and a
certificate that fails hostname/expiry verification. All JSON writes use a
same-directory `mktemp`, `jq -S`, `chmod 0600`, `fsync`, and atomic rename.

- [ ] **Step 2: Implement disabled provider initialization**

`vx_harbor_provider_prepare` creates the fixed tree and a state document with
this exact initial meaning:

```json
{
  "SCHEMA": 1,
  "MODE": "disabled",
  "PINNED_VERSION": "v2.15.0",
  "RUNNING_VERSION": null,
  "INSTALLATION_ID": null,
  "ORIGIN": null,
  "RELEASE_MANIFEST_SHA256": null,
  "LAST_HEALTH_AT": null,
  "LAST_BACKUP_ID": null,
  "LAST_RESTORE_TEST_AT": null,
  "LAST_UPGRADE": null
}
```

No disabled-mode helper may call Docker, systemctl, nginx, curl, package
mutation, firewall, DNS, route, or tenant reconciliation.

- [ ] **Step 3: Run state tests**

```bash
bash test/harbor/test-state.sh
```

Expected: state, ownership, atomic-write, endpoint-derivation, and disabled-mode
no-mutation assertions pass.

- [ ] **Step 4: Commit provider primitives**

```bash
git add func/vx/harbor test/harbor
git commit -m "feat(harbor): add disabled provider authority"
```

### Task 3: Add registry package entitlement and measured usage

**Files:**
- Modify: `func/vx/compose/package.sh`
- Modify: `bin/v-add-user`
- Modify: `bin/v-change-user-package`
- Modify: `bin/v-list-user`
- Modify: `bin/v-list-users`
- Modify: `bin/v-list-user-package`
- Modify: `web/inc/vx_compose_package.php`
- Modify: `web/templates/admin/add_package.html`
- Modify: `web/templates/admin/edit_package.html`
- Modify: `web/templates/admin/list_packages.html`
- Modify: `install/debian/7/packages/default.pkg`
- Modify: `install/debian/7/packages/gainsboro.pkg`
- Modify: `install/debian/7/packages/palegreen.pkg`
- Modify: `install/debian/7/packages/slategrey.pkg`
- Modify: `install/debian/8/packages/default.pkg`
- Modify: `install/debian/8/packages/gainsboro.pkg`
- Modify: `install/debian/8/packages/palegreen.pkg`
- Modify: `install/debian/8/packages/slategrey.pkg`
- Modify: `install/debian/9/packages/default.pkg`
- Modify: `install/debian/9/packages/gainsboro.pkg`
- Modify: `install/debian/9/packages/palegreen.pkg`
- Modify: `install/debian/9/packages/slategrey.pkg`
- Modify: `install/debian/10/packages/default.pkg`
- Modify: `install/debian/11/packages/default.pkg`
- Modify: `install/debian/12/packages/default.pkg`
- Modify: `install/debian/13/packages/default.pkg`
- Modify: `test/compose/test-package-integration.sh`
- Modify: `test/test_compose_package_form.php`
- Create: `test/harbor/test-package-quota.sh`

- [ ] **Step 1: Write failing package tests**

Assert that package and user JSON/plain/shell surfaces contain
`DOCKER_REGISTRY_MB` and `U_DOCKER_REGISTRY_MB`; defaults are `0`; values are a
non-negative integer or `unlimited`; `U_DOCKER_REGISTRY_MB` cannot come from a
package form; and registry bytes do not alter `DOCKER_STORAGE_MB`.

- [ ] **Step 2: Extend package normalization**

Add `DOCKER_REGISTRY_MB` to `VX_COMPOSE_PACKAGE_FIELDS`, default it to `0`, and
include it in package coverage checks. Add a separate measured-usage helper:

```bash
vx_harbor_registry_usage_set() {
    local owner="$1" used_mb="$2"
    [[ "$used_mb" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    update_user_value "$owner" '$U_DOCKER_REGISTRY_MB' "$used_mb"
}
```

Only Harbor observation/reconciliation code calls this helper.

- [ ] **Step 3: Wire package and user persistence**

Persist both fields beside existing Docker dimensions in add/change/list
commands. Package forms accept only `DOCKER_REGISTRY_MB`; render
`U_DOCKER_REGISTRY_MB` read-only from user state. Add
`DOCKER_REGISTRY_MB='0'` to every exact shipped package file listed above.

- [ ] **Step 4: Add transactional package-transition hooks**

Source `func/vx/harbor/main.sh`, take the shared provider lock before the
existing owner access lock, and before `v-change-user-package` writes
`user.conf`, call:

```bash
transition_token="$(vx_harbor_package_transition_prepare \
    "$user" "$DOCKER_REGISTRY_MB")" \
    || check_result "$E_LIMIT" 'Harbor registry quota transition rejected'
```

After the atomic user/package write, call
`vx_harbor_package_transition_commit "$user" "$transition_token"`. On any
failure, restore the exact `user.conf` snapshot and Harbor quota, then leave
the publisher state unchanged. In disabled mode these helpers return a signed
no-op token without network access.

- [ ] **Step 5: Run package tests**

```bash
bash test/compose/test-package-integration.sh
php test/test_compose_package_form.php
bash test/harbor/test-package-quota.sh
```

Expected: all pass, including rejection of a quota below observed Harbor
usage and fail-closed behavior when managed-mode usage is unavailable.

- [ ] **Step 6: Commit package entitlement**

```bash
git add func/vx/compose/package.sh func/vx/harbor bin/v-add-user \
  bin/v-change-user-package bin/v-list-user bin/v-list-users \
  bin/v-list-user-package web/inc/vx_compose_package.php \
  web/templates/admin/add_package.html web/templates/admin/edit_package.html \
  web/templates/admin/list_packages.html install/debian test
git commit -m "feat(harbor): add registry package quota"
```

### Task 4: Add read-only administrator status and endpoint guards

**Files:**
- Create: `func/vx/harbor/status.sh`
- Create: `bin/v-list-harbor-registry`
- Create: `bin/v-list-harbor-registry-owners`
- Modify: `func/vx/harbor/main.sh`
- Modify: `bin/v-change-sys-hostname`
- Modify: `bin/v-change-vesta-port`
- Create: `test/harbor/test-cli-surface.sh`
- Create: `test/harbor/test-endpoint-guards.sh`

- [ ] **Step 1: Write adapter and guard tests**

Require standard Vesta argument checking and exact `json|plain` formats.
Managed mode must reject hostname or panel-port changes before modifying files,
firewall, fail2ban, hostname, or services. Disabled mode preserves current
behavior. A concurrent provider install cannot pass between the mode check and
endpoint mutation.

- [ ] **Step 2: Implement bounded status JSON**

`vx_harbor_status_json` emits exactly these top-level fields:

```json
{
  "MODE": "disabled",
  "ENDPOINT": null,
  "PINNED_VERSION": "v2.15.0",
  "RUNNING_VERSION": null,
  "HEALTH": "unavailable",
  "FRESHNESS": "unavailable",
  "STORAGE_USED_MB": 0,
  "BACKUP_FRESHNESS": "unavailable",
  "CERTIFICATE_EXPIRES": null,
  "PROJECT_COUNT": 0,
  "RECONCILIATION_FAILURES": 0,
  "OBSERVED_AT": null
}
```

Owner listing returns redacted mapping/state/quota/usage/reconcile timestamps
only. It never reads a secret file or includes Harbor numeric IDs.

- [ ] **Step 3: Implement endpoint mutation guards**

Source `func/vx/harbor/main.sh` in both change commands, take the exclusive
provider lock before reading mode, hold it through the existing endpoint
mutation, and execute:

```bash
if vx_harbor_provider_enabled; then
    check_result "$E_FORBIDEN" \
        'managed Harbor must be disabled before changing the Vesta endpoint'
fi
```

Run this after argument/permission validation and before the first mutation.
Release the provider lock from a trap on every exit.

- [ ] **Step 4: Run focused tests and commit milestone 1**

```bash
bash test/harbor/test-cli-surface.sh
bash test/harbor/test-endpoint-guards.sh
bash test/harbor/run-focused.sh
git add func/vx/harbor bin/v-list-harbor-registry \
  bin/v-list-harbor-registry-owners bin/v-change-sys-hostname \
  bin/v-change-vesta-port test/harbor
git commit -m "feat(harbor): expose provider status and endpoint guards"
```

Expected: the complete focused suite for disabled-mode provider authority and
package behavior passes.

- [ ] **Step 5: Perform milestone 1 security/specification review**

Verify R2, R3 state schema, R4 endpoint immutability, and R7 package coverage.
Confirm disabled mode produces no host or tenant mutation and record fixes in
the active milestone before continuing.

## Milestone 2: Verified system service and shared TLS ingress

### Task 5: Pin and verify the complete Harbor release

**Files:**
- Create: `func/vx/harbor/release.sh`
- Create: `install/common/harbor/harbor.yml.template`
- Create: `install/common/harbor/compose.override.yaml`
- Create: `install/common/harbor/generate-release-components.sh`
- Create: `install/common/harbor/release-manifest.json`
- Modify: `func/vx/harbor/main.sh`
- Create: `test/harbor/test-release-manifest.sh`
- Create: `test/harbor/test-release-verification.sh`

- [ ] **Step 1: Define and test the pinned release manifest**

Create `release-manifest.json` with this exact metadata and component map:

```json
{
  "schema": 1,
  "version": "v2.15.0",
  "supported_predecessors": [],
  "installer": {
    "url": "https://github.com/goharbor/harbor/releases/download/v2.15.0/harbor-online-installer-v2.15.0.tgz",
    "sha256": "5b8b2854c16497fbc20f0868991ed6f5a1c1d43b64fecf3652e5c7fca9c7481c",
    "signature_bundle_url": "https://github.com/goharbor/harbor/releases/download/v2.15.0/harbor-online-installer-v2.15.0.tgz.sigstore.json",
    "signature_bundle_sha256": "3880f75e96286d4fe8976b7d8dd1432bee532b2fb01edb7810d30abd1fedc550",
    "certificate_oidc_issuer": "https://token.actions.githubusercontent.com",
    "certificate_identity_regexp": "^https://github.com/goharbor/harbor/.github/workflows/publish_release.yml@refs/tags/v2[.]15[.]0$"
  },
  "components": {
    "goharbor/harbor-core": "goharbor/harbor-core@sha256:32a13f6693a278261e9c9cb7eb606c5e2aa021308ae44fdc73225755048500a8",
    "goharbor/harbor-db": "goharbor/harbor-db@sha256:b54e48a70a7bc173a213f59d826d09bd5d3ad94ab00f2b3335751ff43edeb842",
    "goharbor/harbor-exporter": "goharbor/harbor-exporter@sha256:ad065e4e1a0ee900a0bb1a03d57028ed4b51dc04933f5c1cb5c4aee301a72ddb",
    "goharbor/harbor-jobservice": "goharbor/harbor-jobservice@sha256:a22c7cccba4673b26ffb96f5c37971d85d879dd837bc82448e01c0170b68cf28",
    "goharbor/harbor-log": "goharbor/harbor-log@sha256:a05dbe615a7119095fa9e345324b921e9326a2b335bd3fc4af69a0f0c010aa0b",
    "goharbor/harbor-portal": "goharbor/harbor-portal@sha256:541d5fa95bf77240d46a438f86245cdfd6afa6dd7fdd0cf4dd4c905af6a980b1",
    "goharbor/harbor-registryctl": "goharbor/harbor-registryctl@sha256:463172f71d3a1e8d4f9e3b4e687a447f41fbc3126316d8c150dba04a903bbc47",
    "goharbor/nginx-photon": "goharbor/nginx-photon@sha256:4fcfe831b1d99e3193a586e59ba4984ca2587a9b2998ccd433f8e9425beaabdc",
    "goharbor/prepare": "goharbor/prepare@sha256:ae027b38b3251a5b243e3d642cea6480bafe0f737156beab1ae5d06b1890cd7a",
    "goharbor/redis-photon": "goharbor/redis-photon@sha256:5da5570c0a4c2adae897a30656f1f2f6377f84c11e789b1010732a96b938f34e",
    "goharbor/registry-photon": "goharbor/registry-photon@sha256:beb49fd16cf0906c04a2bf51a22f7210289e7cc2ae43a733e2a0364380aceae6",
    "goharbor/trivy-adapter-photon": "goharbor/trivy-adapter-photon@sha256:6fd6de9cfbbb04cb1d94722cfa01cf71b8994d3f9e7891d3b03a89a7536480ba"
  }
}
```

The test rejects empty/incomplete maps, unknown keys, floating tags, non-HTTPS
URLs, missing digest values, or a permissive signing identity.

- [ ] **Step 2: Generate the exact component map from signed inputs**

`generate-release-components.sh` accepts no version argument. It reads the
committed manifest, downloads only its two fixed URLs, verifies both SHA-256
values, runs:

```bash
cosign verify-blob \
  --bundle harbor-online-installer-v2.15.0.tgz.sigstore.json \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp \
  '^https://github.com/goharbor/harbor/.github/workflows/publish_release.yml@refs/tags/v2[.]15[.]0$' \
  harbor-online-installer-v2.15.0.tgz
```

Then run the verified Harbor `prepare` image, collect every image from the
generated Compose configuration (including Trivy and exporter), resolve each
to `repository@sha256:digest`, and require exact equality with the committed
sorted map. Reject tags, missing/extra components, missing platforms,
duplicate repositories, and a changed installer archive. A deliberate release
refresh may write a reviewed map, but installation never runs this maintainer
script and CI verification is read-only by default.

- [ ] **Step 3: Implement release verification**

`vx_harbor_release_fetch_and_verify STAGE_DIR` requires `cosign >= 2.0`, curl,
jq, tar, Docker, Compose v2, amd64, Debian 12 or 13, and at least the Harbor
recommended CPU/RAM plus twice the configured registry quota in free storage.
It uses fixed binaries under `env -i`, bounded timeouts, downloads to a
root-owned mode-`0700` stage, checks both hashes and the exact signature
identity, rejects links/path traversal while extracting, and compares every
pulled image RepoDigest to the committed component map.

- [ ] **Step 4: Render fixed Harbor configuration**

Render `harbor.yml` with the authoritative Vesta origin, container-internal
HTTP port `8080`,
`external_url` equal to that HTTPS origin, data volume
`/var/lib/vesta-harbor`, private projects, self-registration off, non-admin
project creation off, robot prefix `vxrobot-`, metrics enabled, and generated
secrets read from protected descriptors. Patch the verified generated Harbor
proxy configuration to listen on `/run/vesta-harbor/proxy.sock`, add the
local-only `/__vesta/metrics` upstream, and reject any TCP `listen` directive.
`compose.override.yaml` bind-mounts a root:admin mode-`0750` runtime directory,
publishes no host port, assigns the fixed project network, and preserves exact
image digests. Require the socket itself to be a regular Unix socket mode
`0666`; the non-searchable parent directory is the authority that permits
root and the Vesta nginx `admin` worker while denying tenant Unix users.

- [ ] **Step 5: Run release tests**

```bash
bash install/common/harbor/generate-release-components.sh
bash test/harbor/test-release-manifest.sh
bash test/harbor/test-release-verification.sh
```

Expected: signature verification reports `Verified OK`; the manifest contains
no tag-only image; tampered archive, bundle, identity, image digest,
architecture, and traversal fixtures all fail before extraction or Docker
mutation.

- [ ] **Step 6: Commit pinned release assets**

```bash
git add func/vx/harbor install/common/harbor test/harbor
git commit -m "feat(harbor): pin and verify Harbor v2.15.0"
```

### Task 6: Install the root-owned Harbor system stack transactionally

**Files:**
- Create: `func/vx/harbor/lifecycle.sh`
- Create: `install/common/systemd/vesta-harbor.service`
- Create: `bin/v-install-harbor-registry`
- Modify: `func/vx/harbor/main.sh`
- Create: `test/harbor/test-install.sh`
- Create: `test/harbor/test-system-service.sh`

- [ ] **Step 1: Write failing installation tests**

Prove preflight rejects a non-FQDN, wrong/expired certificate, route collision,
unsupported OS/architecture, low capacity, absent/incompatible panel TLS
listener, unsafe provider paths, missing Cosign, and an already managed or
partially owned service. Prove all failures preserve disabled mode and existing
Docker containers.

- [ ] **Step 2: Implement generated secrets and bootstrap**

Generate independent 256-bit bootstrap, integration, database, Redis, job,
registry, scanner, and age backup identities with `/dev/urandom` or
`age-keygen`; never print them. Store the
bootstrap and routine Basic-auth curl configs separately. Use bootstrap only
to configure Harbor, create the least-privilege system robot, verify its exact
permissions, and then use only `integration.curl` for routine calls. Keep the
age identity out of provider archives, persist its public recipient and
fingerprint in backup metadata, and document separate recovery-key escrow.

- [ ] **Step 3: Install the service unit**

The unit must use this security shape:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/usr/local/vesta/data/harbor/release
ExecStart=/usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/docker compose --project-name vesta-harbor -f docker-compose.yml -f compose.override.yaml up -d --remove-orphans
ExecStop=/usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/docker compose --project-name vesta-harbor -f docker-compose.yml -f compose.override.yaml stop
TimeoutStartSec=900
TimeoutStopSec=300
```

Install it root-owned mode `0644`, daemon-reload, and do not enable/start it
until release, ingress, config, and rollback snapshots are valid.

- [ ] **Step 4: Commit provider state only after readiness**

Start the stack, require every expected component healthy, require local-socket
portal/API/metrics reachability, configure Harbor security settings, and run a
disposable Vesta-owned push/pull check. Only then atomically set mode
`managed`, installation ID, origin, running version, and manifest hash. On
failure stop only `vesta-harbor`, restore config/service snapshots, retain the
staged diagnostics, and leave mode disabled.

- [ ] **Step 5: Run installation tests and commit**

```bash
bash test/harbor/test-install.sh
bash test/harbor/test-system-service.sh
git add func/vx/harbor install/common/systemd bin/v-install-harbor-registry test/harbor
git commit -m "feat(harbor): install managed system stack"
```

### Task 7: Add exact shared-listener registry ingress

**Files:**
- Create: `func/vx/harbor/ingress.sh`
- Create: `install/common/harbor/vesta-nginx-registry.conf.template`
- Modify: `src/deb/for-download/nginx/nginx.conf`
- Modify: `src/deb/for-download/nginx/nginx-deb12.conf`
- Modify: `func/vx/harbor/main.sh`
- Modify: `bin/v-add-sys-vesta-ssl`
- Modify: `bin/v-change-sys-vesta-ssl`
- Modify: `bin/v-update-host-certificate`
- Create: `test/harbor/fixtures/fake-registry-upstream.py`
- Create: `test/harbor/test-ingress.sh`
- Create: `test/harbor/test-certificate-lifecycle.sh`

- [ ] **Step 1: Write path-isolation and protocol tests**

Exercise normal, duplicate-slash, dot-segment, percent-encoded slash/dot,
mixed-case, query, oversized-header/body, unsupported-method, Vesta-cookie,
Harbor-cookie, and Docker Authorization cases. Require:

```text
/v2/ and /v2/<valid OCI path> -> registry upstream only
/service/token                -> token upstream only
/api/, /c/, /harbor/, /metrics -> Vesta 404/403, never Harbor
encoded/path-normalized variants -> 400/404 before panel or Harbor
Docker Authorization on any other path -> 400, never PHP/FastCGI
```

Check `WWW-Authenticate`, `Location`, Host, scheme, client address, and
`Docker-Distribution-Api-Version`; check that request/response cookies and
authorization values never enter access/error logs.

- [ ] **Step 2: Render a dedicated server include**

Use exact/prefix locations that do not rely on a regex fallback. Set a
dedicated redacted log format, a Unix-socket upstream, body/concurrency/connection
limits, upload timeouts, `proxy_set_header Cookie ''`,
`proxy_hide_header Set-Cookie`, preserved Host and forwarding headers, and
`proxy_pass_request_headers on` only in the registry/token locations. The
installer inserts one marked include inside Vesta's existing TLS server; the
two packaged nginx defaults ship the same include for new installations.

- [ ] **Step 3: Make ingress activation transactional**

Render to a temporary file, run the exact Vesta nginx `-t`, atomically install
the include, reload, and require panel login-page and unauthenticated `/v2/`
probes. Roll back include and reload on either failure. Do not run
`v-update-firewall`, edit iptables/nftables, bind a new public socket, or
create DNS/certificate files.

- [ ] **Step 4: Extend certificate changes with dual probes**

After certificate replacement/reload, require the existing panel probe and an
authenticated disposable manifest probe through the external Vesta origin.
If either fails, restore certificate/key and reload; never restart Harbor or
application containers. Certificate-changing commands hold the shared provider
lock from the pre-change snapshot through both successful probes or rollback.

- [ ] **Step 5: Run ingress tests and commit**

```bash
bash test/harbor/test-ingress.sh
bash test/harbor/test-certificate-lifecycle.sh
git add func/vx/harbor install/common/harbor \
  src/deb/for-download/nginx bin/v-add-sys-vesta-ssl \
  bin/v-change-sys-vesta-ssl bin/v-update-host-certificate test/harbor
git commit -m "feat(harbor): proxy OCI traffic on Vesta TLS"
```

### Task 8: Close installation rollback and host-boundary acceptance

**Files:**
- Modify: `func/vx/harbor/lifecycle.sh`
- Modify: `func/vx/harbor/ingress.sh`
- Modify: `bin/v-install-harbor-registry`
- Create: `test/harbor/test-install-rollback.sh`
- Create: `test/harbor/test-host-boundary.sh`

- [ ] **Step 1: Add interruption/fault-injection tests**

Inject failure after download, extraction, image verification, config render,
systemd install, first component start, ingress install, integration-robot
creation, security configuration, and final probe. At every point assert mode
is either fully disabled or fully managed, no public port was added, retained
data is not deleted, and unrelated container IDs are unchanged.

- [ ] **Step 2: Implement one installation transaction journal**

Persist stage names and rollback artifact hashes in
`$VESTA/data/harbor/install-transaction.json`. Recovery on the next install
invocation validates the journal and performs only the inverse actions listed
there. Never use global Docker prune, `down --volumes`, broad recursive delete,
or a caller-provided path.

- [ ] **Step 3: Run milestone 2 tests and review**

```bash
bash test/harbor/test-install-rollback.sh
bash test/harbor/test-host-boundary.sh
bash test/harbor/run-focused.sh
git add func/vx/harbor bin/v-install-harbor-registry test/harbor
git commit -m "fix(harbor): make provider installation recoverable"
```

Verify R1–R5 and the endpoint portions of R12–R13. Inspect effective Compose
ports and nginx routes, not just rendered source. Confirm no tenant workload
is restarted during provider start, stop, fault, or rollback.

## Milestone 3: Owner reconciliation and tenant deployment discovery

### Task 9: Build the allowlisted Harbor API adapter

**Files:**
- Create: `func/vx/harbor/api.sh`
- Modify: `func/vx/harbor/main.sh`
- Create: `test/harbor/test-api.sh`
- Create: `test/harbor/test-api-redaction.sh`

- [ ] **Step 1: Write method/path/schema/redaction tests**

Reject caller-controlled schemes/hosts/ports, unknown methods or routes,
redirects, responses over 1 MiB, malformed JSON, unknown required response
types, slow connect/body responses, CR/LF in paths, and API errors containing a
credential canary. Inspect `/proc/<pid>/cmdline` and `/proc/<pid>/environ`
during a blocked request and prove no secret appears.

- [ ] **Step 2: Implement fixed request identifiers**

Expose no arbitrary URL function. Implement an enum dispatcher such as:

```text
configuration.get        GET /api/v2.0/configurations
configuration.update     PUT /api/v2.0/configurations
health.get               GET /api/v2.0/health
project.list             GET /api/v2.0/projects?name=<encoded-derived-name>
project.create           POST /api/v2.0/projects
project.update           PUT /api/v2.0/projects/<validated-derived-name>
quota.get                GET /api/v2.0/quotas/<state-derived-id>
quota.update             PUT /api/v2.0/quotas/<state-derived-id>
robot.create             POST /api/v2.0/robots
robot.update             PUT /api/v2.0/robots/<state-derived-id>
robot.delete             DELETE /api/v2.0/robots/<state-derived-id>
artifact.get             GET /api/v2.0/projects/<derived>/repositories/<encoded-repository>/artifacts/<digest>
volume.get               GET /api/v2.0/systeminfo/volumes
```

All IDs and names come from validated provider state, not a tenant argument.

- [ ] **Step 3: Keep credentials out of process metadata**

Store curl's `user = "name:secret"` line only in the protected curl config
file and invoke `/usr/bin/curl --config /proc/self/fd/9` with fd 9 opened by
the root caller. Use `--unix-socket /run/vesta-harbor/proxy.sock` with the
fixed request origin `http://harbor.local`, `env -i`, fixed PATH, `--proto =http`,
`--max-redirs 0`, fixed connect/operation timeouts, mode-`0600` request and
response files, and bounded redacted stderr.

- [ ] **Step 4: Run tests and commit**

```bash
bash test/harbor/test-api.sh
bash test/harbor/test-api-redaction.sh
git add func/vx/harbor test/harbor
git commit -m "feat(harbor): add protected API adapter"
```

### Task 10: Reconcile deterministic owner projects and quotas

**Files:**
- Create: `func/vx/harbor/projects.sh`
- Create: `func/vx/harbor/quota.sh`
- Create: `bin/v-sync-harbor-registry-owner`
- Create: `bin/v-sync-harbor-registry-owners`
- Modify: `func/vx/harbor/main.sh`
- Modify: `func/vx/harbor/status.sh`
- Create: `test/harbor/test-owner-mapping.sh`
- Create: `test/harbor/test-owner-reconcile.sh`
- Modify: `test/harbor/test-package-quota.sh`

- [ ] **Step 1: Write mapping and state-machine tests**

Require lowercase `vx-<owner>` only when accepted by Harbor and otherwise
`vx-u-<full lowercase sha256(owner)>`. Test punctuation, maximum Vesta owner
length, non-ASCII rejection at the Vesta boundary, collision detection,
mapping persistence, attempted remapping, missing Harbor project, duplicate
marker, partial robot state, and repeated reconciliation.

- [ ] **Step 2: Implement exact eligibility**

`vx_harbor_owner_eligible OWNER` requires all existing
`vx_compose_shell_require_eligible` facts, owner not `admin`/root,
`DOCKER_PROJECTS` positive or `unlimited`, and `DOCKER_REGISTRY_MB` positive or
`unlimited`. It does not infer eligibility from a running container, existing
Harbor project, group membership alone, or old provider state.

- [ ] **Step 3: Reconcile private project and quota**

Under shared provider then owner access lock, derive/persist the mapping, create or
adopt only a private project carrying this installation ID and hashed owner
marker, configure quota (`-1` for unlimited, otherwise MiB converted with
overflow checks), query authoritative used bytes, and atomically update the
owner observation and `U_DOCKER_REGISTRY_MB`. A reduction below usage fails
before package or Harbor mutation.

- [ ] **Step 4: Implement idempotent adapters**

The single-owner command validates a Vesta user and calls reconciliation. The
all-owner command reads owners from Vesta state, sorts uniquely, takes no owner
argument, continues across failures, emits a bounded summary, and exits
nonzero if any owner failed. Neither command creates workload projects.

- [ ] **Step 5: Run tests and commit**

```bash
bash test/harbor/test-owner-mapping.sh
bash test/harbor/test-owner-reconcile.sh
bash test/harbor/test-package-quota.sh
git add func/vx/harbor bin/v-sync-harbor-registry-owner \
  bin/v-sync-harbor-registry-owners test/harbor
git commit -m "feat(harbor): reconcile private owner projects"
```

### Task 11: Install transactional pull-only runtime credentials

**Files:**
- Create: `func/vx/harbor/credentials.sh`
- Modify: `func/vx/harbor/main.sh`
- Modify: `func/vx/compose/registry.sh`
- Modify: `bin/v-add-docker-registry`
- Modify: `bin/v-delete-docker-registry`
- Create: `bin/v-change-docker-registry`
- Modify: `test/compose/test-registry.sh`
- Create: `test/harbor/test-runtime-credential.sh`
- Create: `test/harbor/test-managed-registry-protection.sh`

- [ ] **Step 1: Write rotation and protection tests**

Prove runtime robots have pull/metadata-read only; publisher permissions are
absent; replacement is validated before activation; API, manifest, Docker
login, metadata-write, and old-robot-delete failures retain the last validated
credential. Generic tenant change/delete must reject only the managed origin
while external registry operations continue unchanged.

- [ ] **Step 2: Extend registry metadata without exposing secrets**

Add these fields to the managed registry record:

```json
{
  "PROVIDER": "harbor-managed",
  "PROVIDER_INSTALLATION_SHA256": "<64 lowercase hex>",
  "GENERATION": 2,
  "ROBOT_USERNAME": "vxrobot-vx-appuser+runtime-g2",
  "LAST_VALIDATION": "succeeded"
}
```

External records retain `PROVIDER: "external"`. Add
`vx_compose_registry_is_provider_managed OWNER REGISTRY` and call it from
generic change/delete adapters before Docker logout or metadata mutation.

- [ ] **Step 3: Implement transactional runtime rotation**

Generate a new secret, create generation N+1 with exact pull permissions,
validate an authenticated manifest request (or a disposable provider-owned
canary when the owner is empty), stage Docker config and metadata in the owner
registry root, atomically install both under the registry lock, then disable
and delete generation N. Destroy secret snapshots on every trap path. If final
old-robot deletion fails, retain N+1 as active and record bounded cleanup debt.

- [ ] **Step 4: Run tests and commit**

```bash
bash test/compose/test-registry.sh
bash test/harbor/test-runtime-credential.sh
bash test/harbor/test-managed-registry-protection.sh
git add func/vx/harbor func/vx/compose/registry.sh bin/v-add-docker-registry \
  bin/v-change-docker-registry bin/v-delete-docker-registry test
git commit -m "feat(harbor): manage pull-only runtime credentials"
```

### Task 12: Add publisher lifecycle and tenant registry discovery

**Files:**
- Create: `bin/v-list-harbor-registry-info`
- Create: `bin/v-change-harbor-registry-publisher`
- Create: `bin/v-disable-harbor-registry-publisher`
- Modify: `bin/v-run-user-docker-command`
- Modify: `func/vx/compose/shell-access.sh`
- Modify: `func/vx/harbor/credentials.sh`
- Modify: `func/vx/harbor/status.sh`
- Modify: `test/compose/fixtures/shell-broker-namespace.sh`
- Modify: `test/compose/test-shell-input.sh`
- Modify: `test/compose/test-shell-access-root-integration.sh`
- Create: `test/harbor/test-publisher.sh`
- Create: `test/harbor/test-registry-info.sh`

- [ ] **Step 1: Write exact broker dispatch tests**

Require:

```text
registry-info app json
  -> v-list-harbor-registry-info <derived-owner> app json
registry-publisher-change + stdin
  -> v-change-harbor-registry-publisher <derived-owner> <root-snapshot-file>
registry-publisher-disable
  -> v-disable-harbor-registry-publisher <derived-owner>
```

Reject owner/profile/URL/registry/project-ID/username/permission arguments,
extra arguments, unsafe project names, secret sizes outside 43..128, non
base64url bytes, linked/nonregular input, disabled provider, and ineligible
owners before API mutation.

Prove Harbor operations acquire the shared provider lock before the owner
access lock and release in reverse order. Ordinary `v-docker health`, logs,
preview, image-pull, apply, and lifecycle operations must not acquire a Harbor
provider lock.

- [ ] **Step 2: Add bounded secret snapshotting**

Extend `vx_compose_shell_snapshot_stdin` with one new enum value,
`publisher`, and cap it at 129 bytes. Require 43–128 bytes matching
`^[A-Za-z0-9_-]+$` with at most one trailing LF and no CR, root-owned mode
`0600`, under the existing validated broker temporary root. Never echo,
persist, hash into user-visible output, or pass secret bytes in
argv/environment. Keep `bin/v-docker` unchanged because it is already a thin
pass-through client.

For the three Harbor operations only, make the broker root-ownership-check and
source `func/vx/harbor/main.sh`, acquire the shared provider lock before
`vx_compose_shell_access_lock_acquire`, and release owner then provider locks
from the existing cleanup trap. Keep the operation allowlist decision ahead of
either lock and preserve the clean environment.

- [ ] **Step 3: Implement publisher create/rotate/disable**

Create exactly one deterministic project robot with repository push plus
required pull permissions and no delete/admin/member/scanner/cross-project
permission. A successful rotation atomically replaces the old generation;
failed validation leaves the old publisher active. Explicit disable marks the
robot disabled and state `publisher-disabled` while leaving runtime pull and
artifacts intact.

- [ ] **Step 4: Implement stable registry-info output**

Return exactly the specification fields and enums. Construct repository as
`REGISTRY/NAMESPACE/PROJECT` from persisted mapping; accept the project name
without requiring a Compose project. Clamp stale/unavailable observations and
never return internal endpoints, IDs, secrets, raw errors, or API payloads.

- [ ] **Step 5: Run shell and tenant tests**

```bash
bash test/compose/test-shell-access.sh
bash test/compose/test-shell-input.sh
bash test/compose/test-shell-access-root-integration.sh
bash test/harbor/test-publisher.sh
bash test/harbor/test-registry-info.sh
```

Expected: all pass; `/proc` and output canaries contain no publisher or runtime
secret.

- [ ] **Step 6: Commit tenant surface**

```bash
git add bin/v-list-harbor-registry-info \
  bin/v-change-harbor-registry-publisher \
  bin/v-disable-harbor-registry-publisher bin/v-run-user-docker-command \
  func/vx/compose/shell-access.sh func/vx/harbor test
git commit -m "feat(harbor): add tenant publishing and discovery"
```

### Task 13: Reconcile revocation through owner lifecycle transitions

**Files:**
- Modify: `bin/v-suspend-user`
- Modify: `bin/v-unsuspend-user`
- Modify: `bin/v-delete-user`
- Modify: `bin/v-change-user-package`
- Modify: `bin/v-change-user-shell`
- Modify: `func/vx/harbor/projects.sh`
- Modify: `func/vx/harbor/credentials.sh`
- Modify: `test/compose/test-owner-lifecycle.sh`
- Create: `test/harbor/test-owner-lifecycle.sh`
- Create: `test/harbor/test-no-deployment-side-channel.sh`

- [ ] **Step 1: Write lifecycle and side-channel tests**

Suspension, admin/root identity, noninteractive shell, lost Docker project
quota, zero registry quota, explicit disable, and deletion must revoke the
publisher under the owner access lock. Unsuspend/re-entitlement must not
re-enable publishing without a new caller secret. Runtime pull and retained
artifacts remain. Harbor push, scan, API, and fixture webhook events must not
touch Compose desired state or invoke pull/apply/deploy/start/stop/route.

- [ ] **Step 2: Add fail-closed lifecycle hooks**

Source `func/vx/harbor/main.sh` and acquire the shared provider lock before
each existing owner access transaction, then call
`vx_harbor_owner_publisher_reconcile "$user"`. For loss/deletion transitions,
require API revocation before reporting success; record desired revoked state
and a reconciliation failure if Harbor is unavailable. User deletion changes
owner state to `retained` and preserves mapping, runtime credential, project,
and image data.

- [ ] **Step 3: Keep re-enablement explicit**

`v-unsuspend-user`, package increase, and shell restoration reconcile private
project/quota/runtime pull only. They leave publisher state
`publisher-disabled` until `registry-publisher-change` receives a new secret.

- [ ] **Step 4: Run milestone 3 tests and review**

```bash
bash test/compose/test-owner-lifecycle.sh
bash test/harbor/test-owner-lifecycle.sh
bash test/harbor/test-no-deployment-side-channel.sh
bash test/harbor/run-focused.sh
git add bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user \
  bin/v-change-user-package bin/v-change-user-shell func/vx/harbor test
git commit -m "feat(harbor): revoke publishers on owner transitions"
```

Verify R6–R11. Run an independent security review of secret handling, broker
identity, lock ordering, package rollback, managed-registry protection, and
absence of any Harbor-to-deployment callback.

## Milestone 4: Operations, recovery, and panel integration

### Task 14: Add health, metrics, observations, and bounded audit

**Files:**
- Create: `func/vx/harbor/health.sh`
- Create: `install/common/systemd/vesta-harbor-observe.service`
- Create: `install/common/systemd/vesta-harbor-observe.timer`
- Modify: `func/vx/harbor/status.sh`
- Modify: `func/vx/harbor/audit.sh`
- Modify: `func/vx/harbor/lifecycle.sh`
- Create: `test/harbor/test-health.sh`
- Create: `test/harbor/test-audit.sh`

- [ ] **Step 1: Write freshness and redaction tests**

Model healthy, degraded, component-down, stale, timeout, malformed metric,
large response, certificate-near-expiry, and API-error states. Audit canaries
must not expose Basic/Bearer headers, robot secrets, request/response bodies,
repository names where a hash is sufficient, or Harbor raw output.

- [ ] **Step 2: Implement bounded observations**

Read only official health, volume, project quota, repository count, and fixed
metric names through the protected local socket. Write normalized observations atomically with
`healthy|degraded|unavailable` and `fresh|stale|unavailable`; never proxy a
Prometheus query. Status commands consume cached observations and perform at
most one bounded refresh.

Install a root-owned oneshot observation service whose two `ExecStart` lines
run `v-list-harbor-registry json` and
`v-sync-harbor-registry-owners` with output suppressed, plus a persistent
15-minute timer with bounded randomized delay. Enable it only in managed mode;
disable it before backup, restore, update, or provider disable. The timer does
not call workload commands.

- [ ] **Step 3: Implement structured provider audit**

Record timestamp, installation hash, owner, operation, result, bounded reason,
provider version, and hashed external identifiers for install/disable,
reconcile, quota, publisher, runtime rotation, API failure, backup/restore,
and update. Cap one record and reason length; sanitize control characters.

- [ ] **Step 4: Run tests and commit**

```bash
bash test/harbor/test-health.sh
bash test/harbor/test-audit.sh
git add func/vx/harbor install/common/systemd test/harbor
git commit -m "feat(harbor): observe and audit provider health"
```

### Task 15: Add consistent encrypted provider backup and restore

**Files:**
- Create: `func/vx/harbor/backup.sh`
- Create: `bin/v-backup-harbor-registry`
- Create: `bin/v-restore-harbor-registry`
- Modify: `func/vx/harbor/main.sh`
- Create: `test/harbor/test-backup.sh`
- Create: `test/harbor/test-restore.sh`

- [ ] **Step 1: Write archive, encryption, and restore tests**

Require an exact manifest of rendered config, provider mappings/metadata,
PostgreSQL dump, blob tree hashes, certificate reference, component digests,
and version. Reject a backup target on the provider/root filesystem, plaintext
secret member, missing age ciphertext, changed member/hash/version, symlink,
path traversal, unvalidated archive, and apply without pre-restore backup.

- [ ] **Step 2: Require a real off-host Vesta backup mount**

Resolve `$BACKUP` from Vesta configuration, require it to be a distinct
mounted filesystem whose source differs from `/` and
`/var/lib/vesta-harbor`, and stage locally only under a protected temporary
directory. Fail before Harbor maintenance if that check or capacity check
fails.

- [ ] **Step 3: Create a consistent encrypted backup**

Under provider lock, prevent new pushes, wait for active uploads/jobs within a
fixed timeout, produce a PostgreSQL dump, hash the blob/config/state trees,
encrypt secret-bearing material with the provider age recipient, assemble a
deterministic archive plus manifest, copy and fsync it to the backup mount,
validate it independently, retain last-known-good metadata, then restore push
availability. Existing application containers remain untouched.

- [ ] **Step 4: Implement validate/apply restore**

Resolve `BACKUP_ID` using `^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$` only below the
configured backup root. `validate` extracts nowhere into provider state and
performs schema/hash/version/decryption/database/blob checks. `apply` requires
a freshly successful validation, creates/validates a pre-restore backup,
stops only Harbor, restores exact config/database/blob/mapping state, starts
and probes all components plus a sample authenticated manifest, reconciles
owners without deleting unmatched projects, and audits success/failure.

- [ ] **Step 5: Run tests and commit**

```bash
bash test/harbor/test-backup.sh
bash test/harbor/test-restore.sh
git add func/vx/harbor bin/v-backup-harbor-registry \
  bin/v-restore-harbor-registry test/harbor
git commit -m "feat(harbor): back up and restore provider state"
```

### Task 16: Add controlled update and immutable disable planning

**Files:**
- Create: `func/vx/harbor/update.sh`
- Create: `func/vx/harbor/disable.sh`
- Create: `bin/v-update-harbor-registry`
- Create: `bin/v-plan-disable-harbor-registry`
- Create: `bin/v-disable-harbor-registry`
- Modify: `func/vx/harbor/main.sh`
- Create: `test/harbor/test-update.sh`
- Create: `test/harbor/test-disable.sh`

- [ ] **Step 1: Write update/disable safety tests**

Reject same/unknown/downgrade/unsupported predecessor, unverified release,
insufficient capacity, absent validated backup, active upload timeout, and a
simulated irreversible migration failure. Disable plans must count dependent
hosts, owner projects, stored bytes, runtime credentials, accepted revisions
whose images use this registry, backup freshness, and retained paths. The
managed host is always a known dependency while accepted revisions reference
the origin. Recent Harbor pull audit from a client address not attributable to
the managed host is reported as a hashed unknown-host dependency and blocks
disable until an administrator establishes replacement authority or the
documented retention window expires. Changed dependencies or expired tokens
must reject apply.

- [ ] **Step 2: Implement source-pinned update**

Read target and predecessor edges only from the committed manifest. Verify
artifacts/capacity, report the maintenance window, block pushes, create and
validate a complete off-host backup, follow Harbor's supported prepare and
database migration sequence, and never claim old containers can reverse an
irreversible schema change. Success requires component health, disposable
push/pull, metrics freshness, and owner reconciliation.

- [ ] **Step 3: Implement plan-bound disable**

Build canonical dependency JSON, hash it, and issue a random short-lived token
stored only as a hash with expiry. Apply re-collects dependencies and requires
the same hash/token, validates replacement authority for accepted workload
images available only here, removes only the nginx include, reloads/probes the
panel, stops only `vesta-harbor`, and sets mode disabled. Retain provider data,
database, blobs, mapping, credentials, backups, workload state, images,
containers, routes, volumes, and revisions. No first-release command purges.

- [ ] **Step 4: Run tests and commit**

```bash
bash test/harbor/test-update.sh
bash test/harbor/test-disable.sh
git add func/vx/harbor bin/v-update-harbor-registry \
  bin/v-plan-disable-harbor-registry bin/v-disable-harbor-registry test/harbor
git commit -m "feat(harbor): control updates and provider disable"
```

### Task 17: Add administrator and tenant panel views

**Files:**
- Create: `web/inc/vx_harbor.php`
- Create: `web/list/harbor/index.php`
- Create: `web/templates/admin/list_harbor.html`
- Create: `web/ajax/harbor/router.php`
- Create: `web/ajax/harbor/actions/install.php`
- Create: `web/ajax/harbor/actions/reconcile.php`
- Create: `web/ajax/harbor/actions/backup.php`
- Create: `web/ajax/harbor/actions/restore_validate.php`
- Create: `web/ajax/harbor/actions/restore_apply.php`
- Create: `web/ajax/harbor/actions/update.php`
- Create: `web/ajax/harbor/actions/disable_plan.php`
- Create: `web/ajax/harbor/actions/disable.php`
- Create: `web/js/pages/list_harbor.js`
- Modify: `web/templates/admin/panel.html`
- Modify: `web/list/docker/index.php`
- Modify: `web/templates/docker_list_shared.php`
- Create: `test/harbor/test-web-ui.php`
- Create: `test/harbor/test-web-jobs.sh`

- [ ] **Step 1: Write access-control and redaction tests**

Require admin-only provider page and mutation routes, authentication and CSRF
for every action, escaped fixed command arguments, bounded job spawning,
owner-only tenant registry information, and no publisher-secret input. Search
rendered HTML/JSON/job argv for bootstrap, integration, runtime, publisher,
Authorization, internal endpoint, and Harbor ID canaries.

- [ ] **Step 2: Render provider status and bounded actions**

Display mode, endpoint, pinned/running versions, component health, storage,
backup freshness, certificate expiry, project count, and reconciliation
failures from `v-list-harbor-registry json`. Use existing
`v-spawn-ajax-process` for install, all-owner reconcile, backup,
restore-validation, update, and disable; disable apply accepts only the exact
plan token returned to the authenticated admin session.

- [ ] **Step 3: Render tenant non-secret discovery**

On the Docker page, show managed state, registry, namespace, publisher
username/enabled, effective quota/usage, and freshness from the same helper as
`registry-info`. Do not add create/rotate publisher forms; instruct tenants to
use bounded-stdin `v-docker registry-publisher-change`.

- [ ] **Step 4: Run web tests and commit milestone 4**

```bash
php test/harbor/test-web-ui.php
bash test/harbor/test-web-jobs.sh
php -l web/inc/vx_harbor.php
php -l web/list/harbor/index.php
php -l web/ajax/harbor/router.php
node --check web/js/pages/list_harbor.js
git add web test/harbor
git commit -m "feat(harbor): add provider panel operations"
```

- [ ] **Step 5: Perform milestone 4 operations/security review**

Verify R12–R16, especially off-host backup evidence, irreversible migration
recovery language, CSRF/authentication, immutable disable plans, zero purge,
and unchanged application container identities during every provider action.

## Milestone 5: Documentation, development acceptance, and release closure

### Task 18: Document operator and application deployment workflows

**Files:**
- Modify: `docs/container-orchestration.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`
- Modify: `.docs/contracts/compose-images.md`
- Modify: `.docs/contracts/compose-shell-access.md`
- Modify: `.docs/contracts/compose-self-service-deployment.md`
- Modify: `.docs/contracts/harbor-provider.md`
- Modify: `.docs/user-guides/docker-compose-projects.md`
- Create: `.docs/user-guides/vesta-managed-harbor.md`
- Create: `.docs/validation/2026-08-08-vesta-managed-harbor-development.md`
- Modify: `.docs/README.md`
- Modify: `test/test_compose_docs.sh`
- Create: `test/harbor/test-docs.sh`

- [ ] **Step 1: Write documentation assertions first**

Require docs to distinguish external tenant credentials, the managed provider
runtime credential, publisher credentials, immutable image authority, and
workload mutation authority. Require all three tenant commands, all ten admin
commands, package fields, current Vesta hostname/port derivation, no extra
DNS/public port/certificate/firewall, backup/restore/update/disable runbooks,
and explicit production deferral.

- [ ] **Step 2: Document provider installation and recovery**

Give operators exact preflight, install, status, owner reconcile, backup,
restore validate/apply, update, disable plan/apply, certificate renewal,
failure recovery, audit, and retained-data checks. State that Harbor v2.15.0
is source-pinned and that a newer release requires a reviewed manifest change,
validated off-host backup, and supported migration edge.

- [ ] **Step 3: Document the framework-neutral adapter sequence**

Include this complete application flow:

```bash
# One-time publisher creation/rotation; retain this value in the application's
# existing local/CI secret store because Vesta never stores or returns it.
PUBLISHER_SECRET="$(openssl rand -base64 48 \
  | tr '+/' '-_' | tr -d '=')"
printf '%s' "$PUBLISHER_SECRET" | ssh appuser@vesta.example.test \
  'v-docker registry-publisher-change'

registry_json="$(ssh appuser@vesta.example.test \
  'v-docker registry-info app json')"
repository="$(jq -er '.REPOSITORY' <<<"$registry_json")"
publisher="$(jq -er '.PUBLISHER_USERNAME' <<<"$registry_json")"

deploy_docker_config="$(mktemp -d)"
chmod 0700 "$deploy_docker_config"
trap 'rm -rf -- "$deploy_docker_config"' EXIT
export DOCKER_CONFIG="$deploy_docker_config"
printf '%s' "$PUBLISHER_SECRET" | docker login \
  "$(jq -er '.REGISTRY' <<<"$registry_json")" \
  --username "$publisher" --password-stdin

[[ "$RELEASE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]
docker buildx build --push --tag "$repository:$RELEASE_ID" .
digest="$(docker buildx imagetools inspect "$repository:$RELEASE_ID" \
  --format '{{json .Manifest.Digest}}' | jq -er '.')"
image="$repository@$digest"

IMAGE_REFERENCE="$image" docker compose -f compose.yaml config \
  > compose.release.yaml
preview="$(ssh appuser@vesta.example.test \
  'v-docker preview app change' < compose.release.yaml)"
preview_id="$(jq -er '.PREVIEW_ID' <<<"$preview")"
source_sha="$(jq -er '.SOURCE_SHA256' <<<"$preview")"
candidate_sha="$(jq -er '.CANDIDATE_SHA256' <<<"$preview")"
revision="$(jq -er '.EXPECTED_CURRENT_REVISION' <<<"$preview")"
ssh appuser@vesta.example.test "v-docker image-pull app $preview_id $source_sha $candidate_sha $revision $image"
ssh appuser@vesta.example.test "v-docker apply app $preview_id $source_sha $candidate_sha $revision"
ssh appuser@vesta.example.test 'v-docker health app json'
ssh appuser@vesta.example.test 'v-docker probe app readiness json'
ssh appuser@vesta.example.test 'v-docker drift app json'
```

Explain that `compose.yaml` declares
`image: ${IMAGE_REFERENCE:?immutable image required}` and that adapters may
use an equivalent existing repository renderer. No application-specific
repository environment variable, SCP/rsync image
archive, Debian SSH, sudo, raw Docker, or Compose-over-SSH is needed.

- [ ] **Step 4: Run documentation tests and commit**

```bash
bash test/test_compose_docs.sh
bash test/harbor/test-docs.sh
git add docs DOCKER_ORCHESTRATION_DEPLOYMENT.md .docs test
git commit -m "docs(harbor): document managed registry deployment"
```

### Task 19: Complete focused and development-host acceptance

**Files:**
- Modify: `test/compose/run-production-readiness.sh`
- Modify: `test/compose/run-production-shellcheck.sh`
- Modify: `test/harbor/run-focused.sh`
- Modify: `.docs/validation/2026-08-08-vesta-managed-harbor-development.md`

- [ ] **Step 1: Add Harbor suites once to readiness**

Call `bash test/harbor/run-focused.sh` once from the canonical readiness
runner. Extend `run-production-shellcheck.sh` so new `bin/v-*-harbor-registry`
adapters and the shared `func/vx/harbor/*.sh` graph are each scanned once;
preserve its existing one-adapter/one-shared-graph design.

- [ ] **Step 2: Run focused static and functional checks**

```bash
find bin -maxdepth 1 -type f -name 'v-*-harbor-registry*' -print0 \
  | xargs -0 -n1 bash -n
find func/vx/harbor test/harbor -type f -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n
bash test/harbor/run-focused.sh
git diff --check
```

Expected: every command exits 0. Do not run broad standalone ShellCheck or the
unlimited canonical readiness gate on this workstation.

- [ ] **Step 3: Stage control-plane files to development**

Use the repository deployment boundary:

```text
local repository
  -> gizmo@192.168.100.16
  -> debian@192.168.100.100
```

Take a rollback backup, deploy only the changed Vesta control-plane files,
install the provider, and record exact commit, file hashes, service state,
effective Unix-socket/public listeners, nginx route probes, component image
digests, and rollback location. Do not mutate a tenant workload.

- [ ] **Step 4: Rehearse one generic tenant publication and deployment**

Create a disposable eligible Vesta user/package/project, generate the
publisher secret locally, reconcile the owner, query `registry-info`, publish
a tiny fixture image, resolve its immutable digest, preview, preview-bound
pull, apply, health/probe/drift verify, then remove the disposable workload
with retained-data semantics. Prove the tenant never gains Docker group,
socket, sudo-to-existing-commands, Harbor portal/API, or another namespace.
As that Unix user, also prove host loopback has no Harbor TCP listener and the
mode-`0750` `/run/vesta-harbor` directory denies direct socket access.

- [ ] **Step 5: Prove provider outage isolation and recovery**

Record an existing disposable application container ID, stop
`vesta-harbor.service`, verify the container remains running and locally
accepted lifecycle operations do not recreate it, verify new push/missing
image pull fail boundedly, restart Harbor, and verify authenticated push/pull
plus owner reconciliation. Record all evidence in the validation document.

- [ ] **Step 6: Run the repository-owned limited readiness gate**

```bash
bash test/compose/run-production-readiness-limited.sh
```

Expected: exit 0 with the canonical readiness runner executed under the
repository's resource limits. Do not set `VX_READINESS_ALLOW_UNLIMITED=yes`.

- [ ] **Step 7: Commit release evidence**

```bash
git add test/compose test/harbor \
  .docs/validation/2026-08-08-vesta-managed-harbor-development.md
git commit -m "test(harbor): validate managed provider readiness"
```

### Task 20: Final specification, security, and repository closeout

**Files:**
- Modify only if review finds a concrete defect: files already named in Tasks
  1–19

- [ ] **Step 1: Audit requirement traceability**

Confirm this mapping with code and test evidence:

```text
R1  Tasks 2, 6, 8, 19       R10 Tasks 12, 18, 19
R2  Tasks 2, 4, 16          R11 Tasks 13, 19
R3  Tasks 2, 5, 6           R12 Tasks 4, 10, 15-17
R4  Tasks 4, 7, 8           R13 Tasks 9, 14
R5  Tasks 6, 9              R14 Task 15
R6  Task 10                 R15 Task 16
R7  Tasks 3, 10             R16 Task 16
R8  Tasks 12, 13            R17 Tasks 18, 19
R9  Tasks 11, 13
```

For each requirement, identify the exact focused test and either fix the gap
inside the owning milestone or keep the release unmerged.

- [ ] **Step 2: Perform final secret and mutation-boundary review**

Inspect argv, environments, temp files, metadata, audit, logs, JSON, HTML,
backups, errors, and process descriptors. Re-run malicious path, cross-owner,
lock interruption, package rollback, credential rotation, restore, update,
disable, and provider-outage cases. Confirm no code path gives Harbor a
workload callback or gives tenants raw Docker/Harbor administration.

- [ ] **Step 3: Verify repository state**

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -20
```

Expected: no uncommitted implementation changes, no whitespace errors, and a
reviewable sequence of milestone commits.

- [ ] **Step 4: Keep production deferred**

Do not install Harbor, change packages, provision robots, alter ingress, or
mutate workloads on any production Vesta host in this plan. A production
rollout requires a separate explicit authorization naming the target host,
Vesta commit, pinned Harbor release, package/user changes, ingress scope,
rollback backup, and workload mutation scope.

## Execution handoff

Recommended execution is milestone-driven: use fresh implementers and focused
tests within each milestone, complete the named security/specification review
at its boundary, and reserve final repository-wide closeout for Task 20.

Alternative execution modes remain available:

1. **Milestone-Driven (recommended):** integrated delivery with milestone
   reviews and final closeout.
2. **Subagent-Driven:** one fresh subagent per independently reviewable task,
   with specification and quality review between tasks.
3. **Inline Execution:** batched implementation in one session with explicit
   checkpoints.
