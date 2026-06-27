# Docker Container Ownership And Panel Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build complete Docker container management for both users and admins in `vesta-vxapp`, including user-facing container creation UI, per-user ownership and quota enforcement, user/admin lifecycle actions, live CPU/RAM/network monitoring, health dashboards, alerts/notifications, long-form operator documentation, exact template-state markup, backup/restore coverage, and domain routing through the existing `vx nginx vx-proxy` flow so a user-owned web domain can proxy traffic to a user-owned container.

**Architecture:** Keep Vortex-specific Docker logic in `vx`-scoped helpers. Persist managed container metadata in `data/users/<user>/docker.conf`, store managed bind data under `$HOMEDIR/$user/docker/<container>/`, publish container ports on `127.0.0.1:<allocated-port>`, and reuse the existing `PROXY_TARGET` / `PROXY_MODE` / `vx-proxy` path already implemented for web domains. Admins get a host-wide overview plus per-user oversight; regular users only see and manage containers they own. Do not support arbitrary host bind paths or unmanaged named volumes in the first complete implementation: keeping writable data under `/home/$user/docker` makes disk quota, cleanup, and backup/restore line up with existing Vesta account boundaries, and routing all public traffic through owned web domains keeps bandwidth accounting on the current nginx/web-domain path instead of inventing a second traffic meter. Live charts should reuse the repo’s existing RRD pipeline, while alerts should reuse the existing Vesta user notification system plus Docker-specific persisted alert state.

**Tech Stack:** Bash CLI commands in `bin/`, Vortex Bash helpers in `func/vx/`, existing Vesta config persistence in `data/users/*`, Docker CLI, PHP panel controllers in `web/`, myVesta modal/AJAX patterns, `v-spawn-ajax-process`, the existing `func/vx/proxy.sh` / `web/inc/vx_proxy_form.php` routing model, the built-in Vesta user-notification commands, and the existing RRD graph/update pipeline under `bin/v-update-sys-rrd*` and `web/rrd/`.

---

## Task 0: Define Contracts, Schemas, And UI State Specs Up Front - COMPLETE

**Files:**
- Create: `.docs/contracts/docker-container-schema.md`
- Create: `.docs/contracts/docker-monitoring-schema.md`
- Create: `.docs/contracts/docker-alerts-schema.md`
- Create: `.docs/contracts/docker-ui-states.md`

- [x] **Step 1: Write the container metadata and create/update spec contract**

Create `.docs/contracts/docker-container-schema.md` with:
- the create/update spec file schema consumed by `bin/v-add-docker-container` and `bin/v-change-docker-container`
- the persisted `data/users/<user>/docker.conf` record schema
- exact field names, types, defaults, allowed values, and validation rules

The spec contract must define at least these create/update fields:

```bash
NAME='app'
IMAGE='ghcr.io/example/app:latest'
COMMAND=''
ENV='PORT=3000||NODE_ENV=production'
MOUNTS='data:/srv/app/data||config:/srv/app/config'
CONTAINER_PORT='3000'
DOMAIN='app.example.com'
ROUTE_PATH=''
AUTO_START='yes'
RESTART_POLICY='unless-stopped'
HEALTHCHECK_TYPE='http'
HEALTHCHECK_TARGET='http://127.0.0.1:3000/health'
HEALTHCHECK_INTERVAL='60'
CPU_ALERT_PCT='85'
MEM_ALERT_MB='1024'
NET_ALERT_MBPS='50'
ALERT_EMAIL='yes'
```

and at least these persisted fields:

```bash
NAME='app' CTN_NAME='vx-jack-app' OWNER='jack' IMAGE='ghcr.io/example/app:latest' COMMAND='' \
ENV='PORT=3000||NODE_ENV=production' MOUNTS='data:/srv/app/data||config:/srv/app/config' \
HOST_PORT='21001' CONTAINER_PORT='3000' DOMAIN='app.example.com' ROUTE_PATH='' \
PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:21001' AUTO_START='yes' \
RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='http' \
HEALTHCHECK_TARGET='http://127.0.0.1:21001/health' HEALTHCHECK_INTERVAL='60' \
HEALTH_STATUS='healthy' LAST_HEALTH_AT='2026-06-27 14:00:00' \
CPU_ALERT_PCT='85' MEM_ALERT_MB='1024' NET_ALERT_MBPS='50' ALERT_EMAIL='yes' \
STATUS='running' CREATED='2026-06-27 14:00:00' UPDATED='2026-06-27 14:05:00'
```

- [x] **Step 2: Write the monitoring schema contract**

Create `.docs/contracts/docker-monitoring-schema.md` with:
- the RRD path convention
- datasource names and units
- the JSON shape returned to the web UI for live charts and dashboard cards
- the polling contract for “live” updates

Use this exact runtime convention:

```text
$RRD/docker/<user>_<name>.rrd
DS:CPU:GAUGE
DS:MEM:GAUGE
DS:RX:DERIVE
DS:TX:DERIVE
```

and this exact JSON contract:

```json
{
  "OWNER": "jack",
  "NAME": "app",
  "PERIOD": "5m",
  "CPU_PCT": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 12.4}],
  "MEM_MB": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 384}],
  "RX_MBPS": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 1.2}],
  "TX_MBPS": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 0.6}],
  "LATEST": {"CPU_PCT": 12.4, "MEM_MB": 384, "RX_MBPS": 1.2, "TX_MBPS": 0.6}
}
```

Define “live” explicitly as:
- chart cards poll JSON endpoints every `60` seconds
- edit-page metric panels refresh every `30` seconds while the page is open
- RRD-backed history charts may lag one sampling interval behind the latest dashboard card values

- [x] **Step 3: Write the alerts and health schema contract**

Create `.docs/contracts/docker-alerts-schema.md` with:
- persisted alert records in `data/users/<user>/docker-alerts.conf`
- health endpoint/status vocabulary
- notification severity mapping to the existing Vesta notification surface

Use this exact alert record shape:

```bash
AID='1' NAME='app' OWNER='jack' LEVEL='warning' TYPE='health' STATUS='open' \
TITLE='Health check failing' MESSAGE='GET /health returned 500 three times' \
STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'
```

Allowed health statuses:

```text
healthy
starting
degraded
unhealthy
unknown
```

- [x] **Step 4: Write the exact UI-state and markup contract**

Create `.docs/contracts/docker-ui-states.md` with:
- every list/add/edit/details page state
- the exact state ids, section ids, card ids, alert ids, and chart container ids that templates must render
- the user/admin differences
- the exact form field names used for automated panel submission

Define at least these exact state containers:

```html
<div id="docker-unavailable-state"></div>
<div id="docker-empty-state"></div>
<div id="docker-quota-reached-state"></div>
<div id="docker-list-state"></div>
<div id="docker-health-dashboard"></div>
<div id="docker-alerts-panel"></div>
<div id="docker-create-form"></div>
<div id="docker-edit-form"></div>
```

Define at least these exact POST field names:

```text
v_container_name
v_container_image
v_container_command
v_container_env
v_container_mounts
v_container_port
v_route_domain
v_auto_start
v_restart_policy
v_healthcheck_type
v_healthcheck_target
v_healthcheck_interval
v_cpu_alert_pct
v_mem_alert_mb
v_net_alert_mbps
v_alert_email
```

- [x] **Step 5: Self-review the contracts before implementation tasks**

Check that every later task in this plan uses the exact same field names:
- `HEALTHCHECK_TYPE`
- `HEALTHCHECK_TARGET`
- `CPU_ALERT_PCT`
- `MEM_ALERT_MB`
- `NET_ALERT_MBPS`
- `HEALTH_STATUS`
- `docker-alerts.conf`

If any later task uses a different name, fix the plan before implementation starts.

#### Closeout Report

- Summary: Created the four Task 0 contract artifacts for Docker container metadata, monitoring, alerts, and exact UI states. Tightened the healthcheck defaulting rules and clarified that the required `docker-create-form` and `docker-edit-form` ids are wrapper containers so later templates can preserve the exact markup contract.
- Files changed: `.docs/contracts/docker-container-schema.md`, `.docs/contracts/docker-monitoring-schema.md`, `.docs/contracts/docker-alerts-schema.md`, `.docs/contracts/docker-ui-states.md`, `.docs/audits/2026-06-27-docker-panel-management-task0.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task0.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `rg`-based contract/name verification against the Task 0 artifacts and later plan references; PASS
- Commit SHA(s): `21bf1683`
- Spec review result: PASS. All Task 0 deliverables were created and the required names remained consistent across the later plan tasks.
- Code quality review result: PASS. The contracts stayed within scope and removed the two main ambiguities found during closeout review: derived healthcheck target defaults and exact create/edit form container interpretation.
- Follow-ups or concerns: None

## Task 1: Define The Ownership Model And Managed Runtime Layout - COMPLETE

**Files:**
- Create: `func/vx/docker.sh`
- Modify: `func/docker.sh`
- Modify: `bin/v-check-docker-engine`
- Modify: `bin/v-list-docker-containers`
- Create: `bin/v-list-docker-container`
- Create: `bin/v-check-docker-container-owner`

- [x] **Step 1: Move Docker-specific state logic into a Vortex helper**

Create `func/vx/docker.sh` and keep `func/docker.sh` as a thin adapter that sources it. The helper must own:
- managed name generation: `vx-${user}-${name}`
- ownership labels: `vx.user`, `vx.name`, `vx.managed=yes`
- metadata file IO for `data/users/$user/docker.conf`
- host port allocation from a reserved localhost-only range
- bind-root creation under `$HOMEDIR/$user/docker/$name`
- ownership validation for admin vs regular-user access
- route sync helpers that write `http://127.0.0.1:${HOST_PORT}` into existing `web.conf` proxy keys

Use the contract from `.docs/contracts/docker-container-schema.md` and persist a concrete metadata shape like this for each record in `data/users/<user>/docker.conf`:

```bash
NAME='app' CTN_NAME='vx-jack-app' OWNER='jack' IMAGE='ghcr.io/example/app:latest' COMMAND='' \
ENV='PORT=3000||NODE_ENV=production' MOUNTS='data:/srv/app/data||config:/srv/app/config' \
HOST_PORT='21001' CONTAINER_PORT='3000' DOMAIN='app.example.com' ROUTE_PATH='' \
PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:21001' AUTO_START='yes' \
RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='http' \
HEALTHCHECK_TARGET='http://127.0.0.1:21001/health' HEALTHCHECK_INTERVAL='60' \
HEALTH_STATUS='healthy' LAST_HEALTH_AT='2026-06-27 14:00:00' \
CPU_ALERT_PCT='85' MEM_ALERT_MB='1024' NET_ALERT_MBPS='50' ALERT_EMAIL='yes' \
STATUS='running' CREATED='2026-06-27 14:00:00' UPDATED='2026-06-27 14:05:00'
```

- [x] **Step 2: Make list/read commands ownership-aware instead of host-global**

Replace the current host-global assumptions in `bin/v-list-docker-containers` with:
- `bin/v-list-docker-containers [USER] [FORMAT]`
- `bin/v-list-docker-container USER NAME [FORMAT]`
- `bin/v-check-docker-container-owner USER NAME`

Concrete command shapes:

```bash
bin/v-list-docker-containers admin json
bin/v-list-docker-containers jack json
bin/v-list-docker-container jack app json
bin/v-check-docker-container-owner jack app
```

Rules:
- when `USER` is `admin`, list every managed container plus owner
- when `USER` is non-admin, list only records from `data/users/$USER/docker.conf`
- container lookups must resolve by metadata record first, then confirm the runtime container carries matching `vx.user` and `vx.name` labels

- [x] **Step 3: Keep the current non-`vx` Docker helper as a compatibility shim**

`func/docker.sh` should stay small:

```bash
#!/bin/bash
source "$VESTA/func/vx/docker.sh"
```

This keeps existing `bin/v-*-docker-*` command paths stable while moving the real behavior into a merge-friendly Vortex file.

- [x] **Step 4: Validate the helper and command syntax**

Run:

#### Closeout Report

- Summary: Added `func/vx/docker.sh` as the Docker ownership/model seam, turned `func/docker.sh` into a compatibility shim, and replaced host-global list behavior with metadata-driven owner-aware `v-list-docker-containers`, `v-list-docker-container`, and `v-check-docker-container-owner` commands.
- Files changed: `func/vx/docker.sh`, `func/docker.sh`, `bin/v-check-docker-engine`, `bin/v-list-docker-containers`, `bin/v-list-docker-container`, `bin/v-check-docker-container-owner`, `.docs/audits/2026-06-27-docker-panel-management-task1.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task1.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `bash -n func/vx/docker.sh func/docker.sh bin/v-check-docker-engine bin/v-list-docker-containers bin/v-list-docker-container bin/v-check-docker-container-owner`; PASS
- Commit SHA(s): `f00b4cd3`
- Spec review result: PASS. Task 1 requirements for the Vortex helper seam, compatibility shim, ownership-aware list/read commands, metadata-first resolution, and syntax validation were satisfied.
- Code quality review result: PASS. The implementation stayed inside the Task 1 seam and reused existing Vesta parsing and proxy helpers instead of introducing a second persistence or routing path.
- Follow-ups or concerns: None

```bash
bash -n func/vx/docker.sh func/docker.sh \
  bin/v-check-docker-engine bin/v-list-docker-containers \
  bin/v-list-docker-container bin/v-check-docker-container-owner
```

---

## Task 2: Add User-Owned Provisioning, Update, And Lifecycle Commands - COMPLETE

**Files:**
- Create: `bin/v-add-docker-container`
- Create: `bin/v-change-docker-container`
- Modify: `bin/v-start-docker-container`
- Modify: `bin/v-stop-docker-container`
- Modify: `bin/v-restart-docker-container`
- Modify: `bin/v-delete-docker-container`
- Modify: `bin/v-list-docker-container-logs`
- Modify: `bin/v-list-docker-container-inspect`
- Create: `bin/v-rebuild-docker-containers`
- Create: `bin/v-sync-docker-container-route`

- [x] **Step 1: Use spec-file based create/change commands**

Follow the repo pattern already used by package forms: write a temporary spec file from PHP, then hand it to Bash.

Concrete command shapes:

```bash
bin/v-add-docker-container jack /tmp/vx-docker-app.conf
bin/v-change-docker-container jack app /tmp/vx-docker-app.conf
```

Use a concrete spec file format:

```bash
NAME='app'
IMAGE='ghcr.io/example/app:latest'
COMMAND=''
ENV='PORT=3000||NODE_ENV=production'
MOUNTS='data:/srv/app/data||config:/srv/app/config'
CONTAINER_PORT='3000'
DOMAIN='app.example.com'
ROUTE_PATH=''
AUTO_START='yes'
RESTART_POLICY='unless-stopped'
HEALTHCHECK_TYPE='http'
HEALTHCHECK_TARGET='http://127.0.0.1:3000/health'
HEALTHCHECK_INTERVAL='60'
CPU_ALERT_PCT='85'
MEM_ALERT_MB='1024'
NET_ALERT_MBPS='50'
ALERT_EMAIL='yes'
```

Create/update flow must:
1. validate the user exists and is unsuspended
2. validate the package allows another container
3. validate `DOMAIN`, when present, belongs to that same user
4. allocate a free `HOST_PORT` on `127.0.0.1`
5. create bind roots only inside `$HOMEDIR/$user/docker/$NAME/`
6. run Docker with labels `vx.user=$user`, `vx.name=$NAME`, `vx.managed=yes`
7. persist the metadata record in `data/users/$user/docker.conf`
8. if `DOMAIN` is set, call `bin/v-sync-docker-container-route`

- [x] **Step 2: Make every lifecycle command enforce ownership**

Update the existing lifecycle/readback commands to require `USER NAME` rather than only container name:

```bash
bin/v-start-docker-container jack app
bin/v-stop-docker-container jack app
bin/v-restart-docker-container jack app
bin/v-delete-docker-container jack app
bin/v-list-docker-container-logs jack app 200
bin/v-list-docker-container-inspect jack app
```

Behavior requirements:
- resolve metadata by `USER + NAME`
- verify the runtime container matches the stored `CTN_NAME`
- delete must also remove proxy routing for `DOMAIN`, free the allocated port, and remove the metadata record
- delete must not delete arbitrary host paths; it may remove `$HOMEDIR/$user/docker/$NAME` only when the container is Vortex-managed

- [x] **Step 3: Add rebuild and route-sync commands**

Create:

```bash
bin/v-sync-docker-container-route jack app
bin/v-rebuild-docker-containers jack
bin/v-rebuild-docker-containers admin
```

`bin/v-sync-docker-container-route` must set:

```bash
bin/v-change-web-domain-proxy-options jack app.example.com \
  'proxy' 'http://127.0.0.1:21001' 'application' 'yes' '60' '' no
```

using the existing `func/vx/proxy.sh` path rather than inventing a new nginx renderer.

`bin/v-rebuild-docker-containers` must iterate metadata records, confirm container runtime state, and reapply domain proxy targets when the linked web domain still exists.

- [x] **Step 4: Validate command syntax**

Run:

```bash
bash -n bin/v-add-docker-container bin/v-change-docker-container \
  bin/v-start-docker-container bin/v-stop-docker-container \
  bin/v-restart-docker-container bin/v-delete-docker-container \
  bin/v-list-docker-container-logs bin/v-list-docker-container-inspect \
  bin/v-rebuild-docker-containers bin/v-sync-docker-container-route
```

#### Closeout Report

- Summary: Added spec-file based Docker create/change commands, converted lifecycle and readback commands to `USER NAME` ownership-safe access, and added route-sync plus rebuild commands on top of the Task 1 metadata helper seam.
- Files changed: `func/vx/docker.sh`, `bin/v-add-docker-container`, `bin/v-change-docker-container`, `bin/v-start-docker-container`, `bin/v-stop-docker-container`, `bin/v-restart-docker-container`, `bin/v-delete-docker-container`, `bin/v-list-docker-container-logs`, `bin/v-list-docker-container-inspect`, `bin/v-sync-docker-container-route`, `bin/v-rebuild-docker-containers`, `.docs/audits/2026-06-27-docker-panel-management-task2.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task2.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `bash -n func/vx/docker.sh bin/v-add-docker-container bin/v-change-docker-container bin/v-start-docker-container bin/v-stop-docker-container bin/v-restart-docker-container bin/v-delete-docker-container bin/v-list-docker-container-logs bin/v-list-docker-container-inspect bin/v-rebuild-docker-containers bin/v-sync-docker-container-route`; PASS
- Commit SHA(s): `110b8feb`
- Spec review result: PASS after fixing two review findings: package-capacity enforcement on change and guaranteed proxy-route removal on delete/domain-switch paths.
- Code quality review result: PASS. The implementation reused the Vortex Docker helper and existing proxy commands instead of introducing a second routing or persistence layer.
- Follow-ups or concerns: None

---

## Task 3: Extend User, Package, Counter, And Stats Persistence - COMPLETE

**Files:**
- Modify: `bin/v-add-user`
- Modify: `bin/v-change-user-package`
- Modify: `bin/v-list-user-package`
- Modify: `bin/v-update-user-package`
- Modify: `bin/v-list-user`
- Modify: `bin/v-list-users`
- Modify: `bin/v-update-user-counters`
- Modify: `bin/v-update-user-stats`
- Modify: `func/main.sh`
- Modify: `web/add/package/index.php`
- Modify: `web/edit/package/index.php`
- Modify: `web/templates/admin/add_package.html`
- Modify: `web/templates/admin/edit_package.html`
- Modify: `web/templates/admin/list_packages.html`
- Modify: `web/templates/admin/list_user.html`
- Modify: `web/templates/admin/edit_user.html`
- Modify: `install/debian/9/packages/default.pkg`
- Modify: `install/debian/9/packages/gainsboro.pkg`
- Modify: `install/debian/9/packages/palegreen.pkg`
- Modify: `install/debian/9/packages/slategrey.pkg`
- Modify: `install/debian/10/packages/default.pkg`
- Modify: `install/debian/11/packages/default.pkg`
- Modify: `install/debian/12/packages/default.pkg`
- Modify: `install/debian/13/packages/default.pkg`
- Modify: `example-of-linux-root-folder/usr/local/vesta/data/packages/default.pkg`
- Modify: `example-of-linux-root-folder/usr/local/vesta/data/users/admin/user.conf`
- Modify: `example-of-linux-root-folder/usr/local/vesta/data/users/test/user.conf`

- [x] **Step 1: Add a package limit and a user counter**

Add:
- `DOCKER_CONTAINERS` to package `.pkg` files and package forms
- `U_DOCKER_CONTAINERS` to `data/users/<user>/user.conf`

Update `bin/v-add-user` so new user records include:

```bash
DOCKER_CONTAINERS='0'
U_DOCKER_CONTAINERS='0'
```

where `DOCKER_CONTAINERS` comes from the selected package and `U_DOCKER_CONTAINERS` starts at `0`.

Mirror the new keys into:
- the synthetic runtime fixtures under `example-of-linux-root-folder/`
- the shipped Debian installer package payloads under `install/debian/*/packages/`

so the forked repo stays internally consistent with the live-host layout described in `AGENTS.md`.

- [x] **Step 2: Make package changes quota-aware**

Update `bin/v-change-user-package`, `bin/v-list-user-package`, `bin/v-update-user-package`, and any limit helpers in `func/main.sh` to recognize the Docker key and reject package downgrades that would leave:

```bash
U_DOCKER_CONTAINERS > DOCKER_CONTAINERS
```

unless the existing `FORCE=yes` path is used.

- [x] **Step 3: Add Docker counters to user listing and monthly stats**

Update:
- `bin/v-list-user`
- `bin/v-list-users`
- `bin/v-update-user-counters`
- `bin/v-update-user-stats`

so Docker usage appears beside the existing web/db/cron counters.

Concrete reporting additions:

```bash
echo "DOCKER:         $U_DOCKER_CONTAINERS/$DOCKER_CONTAINERS"
```

and:

```bash
s="$s U_DOCKER_CONTAINERS='$U_DOCKER_CONTAINERS'"
```

`bin/v-update-user-counters` must count records from `data/users/$user/docker.conf`.

Because public container traffic is required to flow through an owned web domain that uses `vx-proxy`, do not add a separate Docker bandwidth collector in this phase. Document that proxied container traffic continues to count through the existing web-domain bandwidth path, and that direct public host-port publishing is not part of the supported user feature.

- [x] **Step 4: Expose Docker limits in package and user admin pages**

Add a `Docker containers` field to:
- package create/edit pages
- package list view
- user list/edit pages where quotas are summarized

The field name should stay consistent with the CLI key:

```php
$_POST['v_docker_containers']
```

- [x] **Step 5: Validate syntax**

Run:

```bash
bash -n bin/v-add-user bin/v-change-user-package \
  bin/v-list-user bin/v-list-users \
  bin/v-update-user-counters bin/v-update-user-stats

php -l web/add/package/index.php
php -l web/edit/package/index.php
```

#### Closeout Report

- Summary: Added Docker container quota persistence to package and user records, enforced quota-aware package changes, surfaced Docker counters in CLI stats and listings, and exposed the new Docker quota field across the admin package and user quota pages.
- Files changed: `bin/v-add-user`, `bin/v-change-user-package`, `bin/v-list-user-package`, `bin/v-update-user-package`, `bin/v-list-user`, `bin/v-list-users`, `bin/v-update-user-counters`, `bin/v-update-user-stats`, `func/main.sh`, `web/add/package/index.php`, `web/edit/package/index.php`, `web/templates/admin/add_package.html`, `web/templates/admin/edit_package.html`, `web/templates/admin/list_packages.html`, `web/templates/admin/list_user.html`, `web/templates/admin/edit_user.html`, `install/debian/9/packages/default.pkg`, `install/debian/9/packages/gainsboro.pkg`, `install/debian/9/packages/palegreen.pkg`, `install/debian/9/packages/slategrey.pkg`, `install/debian/10/packages/default.pkg`, `install/debian/11/packages/default.pkg`, `install/debian/12/packages/default.pkg`, `install/debian/13/packages/default.pkg`, `example-of-linux-root-folder/usr/local/vesta/data/packages/default.pkg`, `example-of-linux-root-folder/usr/local/vesta/data/users/admin/user.conf`, `example-of-linux-root-folder/usr/local/vesta/data/users/test/user.conf`, `.docs/audits/2026-06-27-docker-panel-management-task3.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task3.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `bash -n bin/v-add-user bin/v-change-user-package bin/v-list-user bin/v-list-users bin/v-update-user-counters bin/v-update-user-stats bin/v-list-user-package bin/v-update-user-package func/main.sh`; PASS. `php -l web/add/package/index.php`; BLOCKED (`php: command not found`). `php -l web/edit/package/index.php`; BLOCKED (`php: command not found`).
- Commit SHA(s): `dcbfd322`, `27111680`
- Spec review result: PASS. The Docker quota key and usage counter now flow through package data, user records, counters, stats, installer payloads, fixtures, and the required admin surfaces.
- Code quality review result: PASS. The implementation stayed merge-friendly by extending existing package/user persistence seams and preserved the planned bandwidth model where proxied container traffic continues to count through the existing web-domain path.
- Follow-ups or concerns: Re-run `php -l web/add/package/index.php` and `php -l web/edit/package/index.php` in an environment that has PHP installed to close the remaining syntax-validation evidence gap.

---

## Task 4: Wire Docker Into User Lifecycle, Suspend/Unsuspend, Backup, Restore, And Delete - COMPLETE

**Files:**
- Modify: `bin/v-suspend-user`
- Modify: `bin/v-unsuspend-user`
- Modify: `bin/v-delete-user`
- Modify: `bin/v-backup-user`
- Modify: `bin/v-list-user-backups`
- Modify: `bin/v-restore-user`
- Modify: `bin/v-schedule-user-restore`
- Modify: `bin/v-rebuild-user`
- Modify: `func/rebuild.sh`

- [x] **Step 1: Stop and resume user-owned containers with account state**

Extend suspend/unsuspend:

```bash
bin/v-suspend-user jack yes
bin/v-unsuspend-user jack yes
```

Rules:
- suspend: stop all owned managed containers and leave metadata intact
- unsuspend: start only containers where `AUTO_START='yes'`
- do not allow a suspended user to create, start, or edit containers

- [x] **Step 2: Remove owned containers before deleting a user**

Extend `bin/v-delete-user` so it:
1. iterates `data/users/$user/docker.conf`
2. removes each managed container
3. clears any linked `PROXY_TARGET` / `PROXY_MODE` values on owned web domains
4. removes `$HOMEDIR/$user/docker`
5. removes `data/users/$user/docker.conf`

This must happen before `$HOMEDIR/$user` and `$USER_DATA` are deleted.

- [x] **Step 3: Back up metadata plus managed bind data**

Extend `bin/v-backup-user` and `bin/v-list-user-backups` to include a Docker section that covers:
- `vesta/docker.conf`
- `vesta/docker-alerts.conf`
- the managed bind-root tree under `$HOMEDIR/$user/docker`

Only managed bind roots under `$HOMEDIR/$user/docker` should be supported. Do not design the feature around arbitrary host bind paths, because those cannot be backed up or safely cleaned up.

- [x] **Step 4: Restore Docker metadata and then rehydrate runtime**

Extend `bin/v-restore-user` and `bin/v-schedule-user-restore` so restore selectors include Docker metadata/data and the runtime rehydration pass:
1. restore `vesta/docker.conf`
2. restore `vesta/docker-alerts.conf`
3. restore `$HOMEDIR/$user/docker`
4. recreate each managed container from metadata
5. re-run `bin/v-sync-docker-container-route $user $name`

Concrete restore pass:

```bash
bin/v-restore-user jack jack.2026-06-27_14-00-00.tar yes yes yes yes yes yes no
bin/v-rebuild-docker-containers jack
```

Landed contract note:
- legacy nine-argument `v-restore-user` calls keep argument 9 as `NOTIFY` and default Docker restore to `yes`
- explicit Docker selection uses the extended form where argument 9 is `DOCKER` and argument 10 is `NOTIFY`
- queued restore uses the extended form automatically

- [x] **Step 5: Reapply routes during generic user rebuild**

Append a Docker rebuild hook to `bin/v-rebuild-user` and any required helper initialization in `func/rebuild.sh`:

```bash
$BIN/v-rebuild-docker-containers "$user"
```

That keeps container route state aligned whenever the user’s web config is rebuilt.

- [x] **Step 6: Validate syntax**

Run:

```bash
bash -n bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user \
  bin/v-backup-user bin/v-restore-user bin/v-rebuild-user
```

#### Closeout Report

- Summary: Wired managed Docker containers into user suspend, unsuspend, delete, backup, restore, and rebuild flows; added Docker backup visibility; and split generic rebuild route refresh from restore-time runtime rehydration so the final implementation stayed within the Task 4 seam after review.
- Files changed: `bin/v-suspend-user`, `bin/v-unsuspend-user`, `bin/v-delete-user`, `bin/v-backup-user`, `bin/v-list-user-backups`, `bin/v-list-user-backup`, `bin/v-restore-user`, `bin/v-schedule-user-restore`, `bin/v-rebuild-user`, `bin/v-rebuild-docker-containers`, `bin/v-start-docker-container`, `bin/v-restart-docker-container`, `func/rebuild.sh`, `func/vx/docker.sh`, `.docs/audits/2026-06-27-docker-panel-management-task4.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task4.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `bash -n bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user bin/v-backup-user bin/v-restore-user bin/v-rebuild-user`; PASS. `bash -n bin/v-list-user-backup bin/v-list-user-backups bin/v-schedule-user-restore bin/v-start-docker-container bin/v-restart-docker-container bin/v-rebuild-docker-containers func/rebuild.sh func/vx/docker.sh`; PASS. `git diff --check`; PASS.
- Commit SHA(s): `a8c78581`, `f327cefa`, `f35e8608`, `5c2a4d42`, `8e35fa65`
- Spec review result: PASS after resolving the restore-selector contract ambiguity by preserving legacy nine-argument calls and keeping the explicit Docker selector on the extended restore form.
- Code quality review result: PASS after tightening generic rebuild back to route alignment, narrowing route cleanup to exact proxy-target matches, adding daemon-availability preflight before destructive restore cleanup, and preserving health metadata on non-restore rebuilds.
- Follow-ups or concerns: Live Docker integration flows were not exercised in this environment, so runtime recreation and route rehydration were validated by code review and shell checks rather than container execution.

---

## Task 5: Add Shared PHP Helpers For Docker Forms And Ownership-Safe Shell Calls - COMPLETE

**Files:**
- Create: `web/inc/vx_docker.php`
- Modify: `web/inc/vx_proxy_form.php`
- Modify: `web/inc/i18n/en.php`

- [x] **Step 1: Centralize Docker form parsing**

Create `web/inc/vx_docker.php` with helpers that mirror the existing proxy helper style:
- normalize container name
- build the temp spec file payload
- convert env/mount textarea input into `||`-joined stored strings
- expose role-aware route/domain dropdown options from the user’s existing web domains
- normalize health-check and alert-threshold fields

Use concrete helper names:

```php
vx_docker_post_value('v_container_name');
vx_docker_env_from_post();
vx_docker_mounts_from_post();
vx_docker_healthcheck_from_post();
vx_docker_alert_thresholds_from_post();
vx_docker_write_spec_file($tmpdir, $spec);
```

- [x] **Step 2: Keep proxy helpers unchanged except for Docker-specific reuse**

Do not duplicate proxy parsing. Where the Docker forms need to show the eventual proxy target, call the existing proxy helpers and the Docker helper side-by-side.

- [x] **Step 3: Add explicit strings for owned-container UX**

Add UI strings for:
- `Docker containers`
- `Add Docker container`
- `Container image`
- `Container port`
- `Route domain`
- `Environment variables`
- `Bind mounts`
- `Health checks`
- `Health status`
- `CPU usage`
- `Memory usage`
- `Network traffic`
- `Alerts`
- `No active alerts`
- `Live metrics`
- `Degraded`
- `Unhealthy`
- `Only domains owned by this user can be routed to this container`
- `Only managed bind roots under /home/<user>/docker are allowed`

- [x] **Step 4: Validate syntax**

Run:

```bash
php -l web/inc/vx_docker.php
php -l web/inc/vx_proxy_form.php
```

#### Closeout Report

- Summary: Added the shared Docker PHP helper seam for upcoming CRUD pages, kept proxy helpers reusable, extended the English language pack with the required owned-container strings, and tightened the Docker temp spec contract so PHP-written helper payloads round-trip safely into the Bash-side Docker loader.
- Files changed: `web/inc/vx_docker.php`, `web/inc/vx_proxy_form.php`, `web/inc/i18n/en.php`, `func/vx/docker.sh`, `.docs/audits/2026-06-27-docker-panel-management-task5.audit-input.md`, `.docs/audits/2026-06-27-docker-panel-management-task5.audit.md`, `.docs/plans/2026-06-27-docker-panel-management.md`
- Tests run: `php -l web/inc/vx_docker.php`; BLOCKED (`php: command not found`). `php -l web/inc/vx_proxy_form.php`; BLOCKED (`php: command not found`). `php -l web/inc/i18n/en.php`; BLOCKED (`php: command not found`). `bash -n func/vx/docker.sh`; PASS.
- Commit SHA(s): `950db930`, `a7490589`, `d2b24e69`, `ed6b9cff`
- Spec review result: PASS after preserving route-domain metadata for later role-aware Docker forms while keeping the helper scope inside the Task 5 seam.
- Code quality review result: PASS after aligning POST-field names with the later Docker form contract, removing the backwards proxy-to-Docker include, tightening helper normalization, and replacing the generic parser toggle with a Docker-specific temp spec parser.
- Follow-ups or concerns: PHP syntax validation still needs to be rerun in an environment with a `php` binary; the helper runtime behavior itself is otherwise validated by review and Bash syntax checks.

---

## Task 6: Build The User-Facing Docker CRUD Pages And Admin Oversight Pages

**Files:**
- Modify: `web/list/docker/index.php`
- Create: `web/add/docker/index.php`
- Create: `web/edit/docker/index.php`
- Modify: `web/start/docker/index.php`
- Modify: `web/stop/docker/index.php`
- Modify: `web/restart/docker/index.php`
- Create: `web/delete/docker/index.php`
- Modify: `web/ajax/docker/index.php`
- Modify: `web/ajax/docker/router.php`
- Create: `web/ajax/docker/actions/stats.php`
- Create: `web/ajax/docker/actions/health.php`
- Create: `web/ajax/docker/actions/alerts.php`
- Create: `web/ajax/docker/actions/acknowledge_alert.php`
- Modify: `web/ajax/docker/actions/remove.php`
- Modify: `web/ajax/docker/actions/logs.php`
- Modify: `web/ajax/docker/actions/inspect.php`
- Modify: `web/ajax/docker/actions/install.php`
- Create: `web/js/pages/list_docker.js`
- Create: `web/js/pages/edit_docker.js`
- Create: `web/templates/admin/add_docker.html`
- Create: `web/templates/admin/edit_docker.html`
- Modify: `web/templates/admin/list_docker.html`
- Create: `web/templates/user/list_docker.html`
- Create: `web/templates/user/add_docker.html`
- Create: `web/templates/user/edit_docker.html`

- [ ] **Step 1: Turn the Docker list controller into a role-aware page**

`web/list/docker/index.php` must stop redirecting non-admin users away. Replace that with:
- admin: host-wide managed container list, filterable by owner
- user: only owned container list

Use the ownership-aware CLI:

```php
exec(VESTA_CMD."v-list-docker-containers ".$user." json", $output, $return_var);
```

and for admin “all containers”:

```php
exec(VESTA_CMD."v-list-docker-containers admin json", $output, $return_var);
```

- [ ] **Step 2: Add create/edit forms**

Create `web/add/docker/index.php` and `web/edit/docker/index.php` using the same pattern as `web/add/web/index.php` and `web/edit/web/index.php`:
- token check
- role-aware user selection
- build temp spec file
- call `v-add-docker-container` or `v-change-docker-container`
- on success, redirect back to `/list/docker/`

Admins may manage another user’s containers only by explicitly passing `?user=<name>`; regular users always operate on their own `$user`.

- [ ] **Step 3: Make start/stop/restart/delete pages ownership-safe**

Update the lifecycle pages to call the new command signatures:

```php
exec(VESTA_CMD."v-start-docker-container ".$owner." ".$container, $output, $return_var);
exec(VESTA_CMD."v-stop-docker-container ".$owner." ".$container, $output, $return_var);
exec(VESTA_CMD."v-restart-docker-container ".$owner." ".$container, $output, $return_var);
exec(VESTA_CMD."v-delete-docker-container ".$owner." ".$container, $output, $return_var);
```

Regular users may only act on their own records; admin may pass an explicit owner.

- [ ] **Step 4: Separate admin-only Docker install from normal container actions**

Keep engine install admin-only in the AJAX flow, but let logs/inspect/remove work for users on owned containers.

Concrete split:
- `web/ajax/docker/index.php`: admin may see `Install Docker`; users never do
- `web/ajax/docker/router.php`: gate each action separately instead of blanket `admin` auth
- `web/ajax/docker/actions/install.php`: keep admin-only
- `web/ajax/docker/actions/logs.php`, `inspect.php`, `remove.php`: validate ownership through `$myvesta_logged_user` and the selected owner/name pair

- [ ] **Step 5: Put container-routing fields directly in the Docker forms**

The add/edit forms must include:
- container name
- image
- command
- environment variables textarea
- bind mounts textarea using relative roots like `data:/srv/app/data`
- container port
- route domain dropdown populated from the user’s existing web domains
- restart policy
- auto-start
- health-check type
- health-check target/path
- health-check interval
- CPU / memory / network alert thresholds
- alert delivery toggle

Do not add free-form nginx target input. The user should choose `container port + route domain`, and the backend should derive the proxy target from the allocated localhost port.

- [ ] **Step 6: Add the live dashboard and alert panels to the list and edit pages**

Render the exact containers defined in `.docs/contracts/docker-ui-states.md` and populate them through `web/js/pages/list_docker.js` and `web/js/pages/edit_docker.js`.

Each populated container card must show:
- latest CPU
- latest memory
- latest RX/TX
- current health status badge
- alert count
- last health-check time

Each page must have explicit empty/no-data states, not just hidden panels.
Use the monitoring contract’s polling intervals exactly, and include an alert-acknowledge control in the alerts panel for open alerts.

- [ ] **Step 7: Validate syntax**

Run:

```bash
php -l web/list/docker/index.php
php -l web/add/docker/index.php
php -l web/edit/docker/index.php
php -l web/start/docker/index.php
php -l web/stop/docker/index.php
php -l web/restart/docker/index.php
php -l web/delete/docker/index.php
php -l web/ajax/docker/index.php
php -l web/ajax/docker/router.php
php -l web/ajax/docker/actions/stats.php
php -l web/ajax/docker/actions/health.php
php -l web/ajax/docker/actions/alerts.php
php -l web/ajax/docker/actions/acknowledge_alert.php
php -l web/ajax/docker/actions/remove.php
php -l web/ajax/docker/actions/logs.php
php -l web/ajax/docker/actions/inspect.php
php -l web/ajax/docker/actions/install.php
```

---

## Task 7: Expose Docker In The User And Admin Panel Navigation

**Files:**
- Modify: `web/templates/admin/panel.html`
- Modify: `web/templates/user/panel.html`
- Modify: `web/templates/admin/list_services.html`

- [ ] **Step 1: Keep the host-level Docker entry under Server for admins**

Retain the current admin `Server` placement in `web/templates/admin/list_services.html`, but change the meaning of the page from “all host containers” to “all Vortex-managed containers, grouped by owner”.

- [ ] **Step 2: Add a quota-driven Docker entry to both admin and user side panels**

Add a stats tile in both panel templates that is shown only when:

```php
$panel[$user]['DOCKER_CONTAINERS'] != "0"
```

and displays:

```php
<?=__('DOCKER')?><span><?=$panel[$user]['U_DOCKER_CONTAINERS']?></span>
```

with the tile linking to `/list/docker/`.

- [ ] **Step 3: Preserve the existing admin/user panel split**

Because `render_page()` loads `web/templates/user/$page.html` for non-admin users first, create user-specific list/add/edit Docker templates instead of relying on admin templates to serve both roles.

---

## Task 8: Reuse Existing vx-proxy Web-Domain Routing Instead Of Inventing New Nginx State

**Files:**
- Modify: `func/vx/proxy.sh`
- Modify: `bin/v-add-web-domain`
- Modify: `bin/v-change-web-domain-proxy-options`
- Modify: `web/add/web/index.php`
- Modify: `web/edit/web/index.php`

- [ ] **Step 1: Treat Docker routes as a producer of existing `PROXY_TARGET` values**

Do not add a second routing system. The Docker feature must only write:
- `PROXY_MODE`
- `PROXY_TARGET`
- `PROXY_PROFILE`
- `PROXY_PRESERVE_HOST`
- `PROXY_TIMEOUT`
- `PROXY_HEADERS`

to the existing web-domain record, then rely on `func/vx/proxy.sh` and `vx-proxy.tpl` to render nginx.

- [ ] **Step 2: Add minimal guardrails to the current web-domain flows**

When a domain is already linked to a managed Docker container:
- the Docker page should be the place that owns the target
- the web-domain edit page may still render the proxy fields, but changing the target there should either clear the Docker link or refuse the edit with an explicit message

Persist that relationship in Docker metadata with:

```bash
DOMAIN='app.example.com'
PROXY_TARGET='http://127.0.0.1:21001'
```

- [ ] **Step 3: Rebuild route state from Docker metadata, not generated nginx files**

Any rebuild/recovery path must read `data/users/<user>/docker.conf`, then call `bin/v-sync-docker-container-route`. Never parse rendered nginx files as the source of truth.

---

## Task 9: Add Metrics, Health, And Alert Pipelines

**Files:**
- Modify: `func/vx/docker.sh`
- Modify: `func/rebuild.sh`
- Modify: `bin/v-update-sys-rrd`
- Create: `bin/v-update-sys-rrd-docker`
- Create: `bin/v-list-docker-container-stats`
- Create: `bin/v-update-docker-container-health`
- Create: `bin/v-list-docker-container-health`
- Create: `bin/v-list-docker-container-alerts`
- Create: `bin/v-acknowledge-docker-container-alert`

- [ ] **Step 1: Add per-container RRD sampling for live charts**

Create `bin/v-update-sys-rrd-docker` and have `bin/v-update-sys-rrd` call it with the same period loop used for existing system graphs.

Use the contract from `.docs/contracts/docker-monitoring-schema.md`:

```bash
$BIN/v-update-sys-rrd-docker daily
$BIN/v-update-sys-rrd-docker weekly
$BIN/v-update-sys-rrd-docker monthly
$BIN/v-update-sys-rrd-docker yearly
```

The command must:
- iterate all managed containers from `docker.conf`
- sample CPU, memory, RX, and TX from `docker stats --no-stream`
- update `$RRD/docker/<user>_<name>.rrd`
- render chart PNGs beside the RRD using the repo’s existing graph pattern

- [ ] **Step 2: Add stats list commands for the web UI**

Create:

```bash
bin/v-list-docker-container-stats jack app 5m json
bin/v-list-docker-container-stats jack app 5m json
```

The JSON response must match `.docs/contracts/docker-monitoring-schema.md` exactly so the JS chart layer does not invent field names ad hoc.

Admin access should reuse the same owner-qualified command and only bypass the ownership check internally:

```bash
bin/v-list-docker-container-stats jack app 5m json
```

- [ ] **Step 3: Add health-check sampling and persisted state**

Create:

```bash
bin/v-update-docker-container-health jack app
bin/v-list-docker-container-health jack app json
```

Health evaluation order:
1. Docker native health status from `docker inspect`, if present
2. explicit HTTP/TCP target from `HEALTHCHECK_TYPE` and `HEALTHCHECK_TARGET`
3. fallback status `unknown`

Persist the result back into `docker.conf`:

```bash
HEALTH_STATUS='healthy'
LAST_HEALTH_AT='2026-06-27 14:00:00'
```

- [ ] **Step 4: Add alert generation and notification fan-out**

Create:

```bash
bin/v-list-docker-container-alerts jack app json
```

and use `data/users/<user>/docker-alerts.conf` as the persisted alert source of truth. Alert producers must open or update records when:
- health becomes `degraded` or `unhealthy`
- CPU exceeds `CPU_ALERT_PCT`
- memory exceeds `MEM_ALERT_MB`
- RX or TX exceeds `NET_ALERT_MBPS`

For newly opened alerts, call the existing notification command:

```bash
$BIN/v-add-user-notification "$user" "Docker alert: app unhealthy" "/list/docker/"
```

Closed-loop alert handling must also support:

```bash
bin/v-acknowledge-docker-container-alert jack 1
```

which sets `ACK='yes'` on the persisted Docker alert record without deleting the underlying history.

- [ ] **Step 5: Rebuild the monitoring files during user rebuild**

Extend `func/rebuild.sh` to ensure:
- `data/users/<user>/docker-alerts.conf` exists with correct permissions
- `$RRD/docker/` exists
- the Docker monitoring rebuild pass can regenerate charts after restore/rebuild

- [ ] **Step 6: Validate syntax**

Run:

```bash
bash -n func/vx/docker.sh func/rebuild.sh bin/v-update-sys-rrd \
  bin/v-update-sys-rrd-docker bin/v-list-docker-container-stats \
  bin/v-update-docker-container-health bin/v-list-docker-container-health \
  bin/v-list-docker-container-alerts bin/v-acknowledge-docker-container-alert
```

---

## Task 10: Add Exact Template Markup, Long-Form Docs, And Screenshot Deliverables

**Files:**
- Create: `.docs/user-guides/docker-containers.md`
- Create: `.docs/user-guides/assets/docker/README.md`
- Modify: `web/templates/admin/list_docker.html`
- Modify: `web/templates/user/list_docker.html`
- Create: `web/templates/admin/add_docker.html`
- Create: `web/templates/user/add_docker.html`
- Create: `web/templates/admin/edit_docker.html`
- Create: `web/templates/user/edit_docker.html`

- [ ] **Step 1: Document every user-facing workflow in a long-form guide**

Create `.docs/user-guides/docker-containers.md` with explicit sections for:
1. prerequisites and package limits
2. creating a container
3. routing a domain to a container
4. reading charts and health state
5. handling alerts
6. viewing logs and inspect output
7. deleting and restoring a container

The guide must show the actual field names used in the forms, not generic paraphrases.

- [ ] **Step 2: Add a screenshot manifest for required captures**

Create `.docs/user-guides/assets/docker/README.md` listing the exact screenshots implementation must capture after the UI exists:

```text
user-list-empty.png
user-list-populated.png
user-create-form.png
user-edit-health-dashboard.png
user-alerts-panel.png
admin-owner-overview.png
admin-docker-unavailable.png
```

For each image, document:
- page URL
- login role
- required seed data
- exact state visible in the capture

- [ ] **Step 3: Implement exact final template markup for every page state**

Use `.docs/contracts/docker-ui-states.md` as the source of truth. The templates must render exact state containers, not loosely equivalent markup.

At minimum, `list_docker` templates must implement:

```html
<div id="docker-unavailable-state" class="l-unit l-unit--error"></div>
<div id="docker-empty-state" class="l-unit"></div>
<div id="docker-quota-reached-state" class="l-unit l-unit--suspended"></div>
<div id="docker-list-state" class="l-center units"></div>
<section id="docker-health-dashboard" class="l-center units"></section>
<section id="docker-alerts-panel" class="l-center units"></section>
<button id="docker-alert-acknowledge"></button>
```

`add_docker` and `edit_docker` templates must implement:

```html
<form id="docker-create-form"></form>
<form id="docker-edit-form"></form>
<div id="docker-form-errors"></div>
<section id="docker-live-metrics"></section>
<section id="docker-health-settings"></section>
<section id="docker-alert-thresholds"></section>
```

- [ ] **Step 4: Verify template/docs completeness**

Check the final docs/template set against this required state list:
- Docker unavailable
- Empty owned-container list
- Quota-reached creation state
- Healthy container with charts
- Degraded/unhealthy container with alerts
- Validation-error state on create/edit
- Admin multi-owner overview

If any state is not explicitly documented and mapped to exact template markup, update the plan before implementation starts.

---

## Task 11: Install Playwright For Panel UI Validation

**Files:**
- Create: `package.json`
- Create: `package-lock.json`
- Modify: `.gitignore`
- Create: `.env.playwright.example`
- Create: `playwright.config.js`
- Create: `tests/playwright/README.md`
- Create: `tests/playwright/helpers/panel-auth.js`
- Create: `tests/playwright/auth.setup.js`
- Create: `tests/playwright/login-page.anonymous.spec.js`
- Create: `tests/playwright/panel-shell.admin.authenticated.spec.js`
- Create: `tests/playwright/panel-shell.user.authenticated.spec.js`

- [ ] **Step 1: Add repo-local Playwright tooling instead of reusing unrelated nested packages**

Create a root-level `package.json` dedicated to panel UI validation and install only the required dependencies:

```bash
npm init -y
npm install -D @playwright/test dotenv
npx playwright install chromium
```

`package.json` must expose at least these exact scripts:

```json
{
  "scripts": {
    "playwright:install": "npx playwright install chromium",
    "playwright:test": "npx playwright test",
    "playwright:test:headed": "npx playwright test --headed",
    "playwright:test:ui": "npx playwright test --ui",
    "playwright:report": "npx playwright show-report"
  }
}
```

Update `.gitignore` so browser artifacts and local auth state do not dirty the repo:

```text
node_modules/
playwright-report/
test-results/
playwright/.auth/
.env.playwright
.env.playwright.local
```

- [ ] **Step 2: Define the project matrix and environment contract up front**

Create `.env.playwright.example` with these exact variables:

```bash
PLAYWRIGHT_BASE_URL=https://192.168.100.100:8083
PLAYWRIGHT_LOGIN_SECRET=
PLAYWRIGHT_ADMIN_USER=admin
PLAYWRIGHT_ADMIN_PASSWORD=
PLAYWRIGHT_DOCKER_USER=dockere2e
PLAYWRIGHT_DOCKER_PASSWORD=ChangeMe-123!
```

Create `playwright.config.js` with four project classes:
- `setup`
- `chromium-anonymous`
- `chromium-admin-authenticated`
- `chromium-docker-user-authenticated`

Rules:
- anonymous tests always run
- authenticated projects are enabled only when the matching credentials are present
- all projects must use `ignoreHTTPSErrors: true`
- the default base URL must be `https://192.168.100.100:8083`
- the admin project must load `playwright/.auth/admin.json`
- the real non-admin project must load `playwright/.auth/docker-user.json`

- [ ] **Step 3: Encode authentication so Docker UI tests are not blocked by panel security layers**

Create `tests/playwright/helpers/panel-auth.js` and `tests/playwright/auth.setup.js`.

The helper must:
- load `PLAYWRIGHT_ENV_FILE` or `.env.playwright`
- handle the optional secret-login gate by visiting `/?<secret>` before `/login/`
- perform a real browser login and wait for the panel shell URL
- expose role-based credential lookups for `admin` and `dockerUser`
- persist auth state under `playwright/.auth/`

Use concrete helper functions:

```js
getPanelCredentials('admin');
getPanelCredentials('dockerUser');
hasPanelCredentials('admin');
hasPanelCredentials('dockerUser');
loginWithPassword(page, credentials);
openPanelLogin(page);
getAuthStatePath('admin');
getAuthStatePath('dockerUser');
```

The setup spec must create storage state for every configured role in one run so future Docker specs can target either:

```js
setup('create authenticated storage states for configured panel roles', async ({ browser, baseURL }) => {
  // login admin when configured
  // login dockerUser when configured
  // write playwright/.auth/admin.json and playwright/.auth/docker-user.json
});
```

- [ ] **Step 4: Add smoke tests that prove the harness can reach the panel before Docker work begins**

Create these smoke specs:

```text
tests/playwright/login-page.anonymous.spec.js
tests/playwright/panel-shell.admin.authenticated.spec.js
tests/playwright/panel-shell.user.authenticated.spec.js
```

Minimum assertions:
- anonymous login page renders `form[action="/login/"]`
- anonymous login page renders `input[name="token"]`
- admin shell renders `.l-header`, `#token`, and `.l-profile__logout`
- real non-admin shell renders `.l-header`, `#token`, and `.l-profile__logout`

The user shell smoke must use a normal user page such as `/list/web/`, not an admin-only path.

- [ ] **Step 5: Document how to run the harness and verify setup**

Create `tests/playwright/README.md` with:
- environment-file instructions
- the optional secret-login explanation
- the project matrix
- the command to install Linux shared-library deps if required:

```bash
npx playwright install-deps chromium
```

Then verify the harness loads:

```bash
npm run playwright:test -- --list
PLAYWRIGHT_ENV_FILE=.env.playwright.example npm run playwright:test -- --list
```

Expected:
- the anonymous project is listed even with no local secrets
- the docker-user project is listed when the example env file is supplied
- no spec execution starts during the `--list` validation pass

---

## Task 12: Add Regression Coverage And Docker-Specific Playwright UI Tests

**Files:**
- Create: `test/test_docker_user_actions.sh`
- Modify: `test/test_json_listing.sh`
- Modify: `test/test_actions.sh`
- Create: `tests/playwright/docker-navigation.user.authenticated.spec.js`
- Create: `tests/playwright/docker-access-control.admin.authenticated.spec.js`
- Create: `tests/playwright/docker-empty-state.user.authenticated.spec.js`
- Create: `tests/playwright/docker-create-form.user.authenticated.spec.js`
- Create: `tests/playwright/docker-lifecycle.user.authenticated.spec.js`
- Create: `tests/playwright/docker-modals.user.authenticated.spec.js`
- Create: `tests/playwright/docker-dashboard.user.authenticated.spec.js`

- [ ] **Step 1: Keep shell regression coverage for ownership, routing, and restore behavior**

Add shell tests that exercise:
- user can create a container when `DOCKER_CONTAINERS > U_DOCKER_CONTAINERS`
- user cannot create a container when the package limit is exhausted
- user cannot start/stop/delete another user’s container
- admin can inspect and manage another user’s container
- user can acknowledge an open Docker alert without acknowledging another user’s alert
- `v-list-web-domain <user> <domain> json` and `v-list-docker-container <user> <name> json` agree on `PROXY_TARGET`
- backup/restore returns `docker.conf`, alert data, bind-root data, and the route link

- [ ] **Step 2: Add Playwright coverage for navigation and access control**

Create:

```text
tests/playwright/docker-navigation.user.authenticated.spec.js
tests/playwright/docker-access-control.admin.authenticated.spec.js
```

`docker-navigation.user.authenticated.spec.js` must assert:
- the user side-panel tile links to `/list/docker/` when `DOCKER_CONTAINERS != 0`
- `/list/docker/` renders one of:
  - `#docker-unavailable-state`
  - `#docker-empty-state`
  - `#docker-list-state`

`docker-access-control.admin.authenticated.spec.js` must assert:
- admin `Server` navigation still links to the Docker page
- admin sees owner-aware Docker rows
- admin can filter or pivot by owner when multiple managed containers exist

- [ ] **Step 3: Add Playwright coverage for empty state, create form, and lifecycle actions**

Create:

```text
tests/playwright/docker-empty-state.user.authenticated.spec.js
tests/playwright/docker-create-form.user.authenticated.spec.js
tests/playwright/docker-lifecycle.user.authenticated.spec.js
```

Required assertions:
- empty owned-container state renders `#docker-empty-state`
- quota-exhausted users render `#docker-quota-reached-state`
- the add form renders all contracted field names from `.docs/contracts/docker-ui-states.md`
- form validation errors render inside `#docker-form-errors`
- successful create redirects back to `/list/docker/`
- start/stop/restart flows update the row state and action labels without exposing admin-only engine controls

Use the exact contracted POST field names during form submission:

```text
v_container_name
v_container_image
v_container_command
v_container_env
v_container_mounts
v_container_port
v_route_domain
v_auto_start
v_restart_policy
v_healthcheck_type
v_healthcheck_target
v_healthcheck_interval
v_cpu_alert_pct
v_mem_alert_mb
v_net_alert_mbps
v_alert_email
```

- [ ] **Step 4: Add Playwright coverage for modals, charts, health, and alerts**

Create:

```text
tests/playwright/docker-modals.user.authenticated.spec.js
tests/playwright/docker-dashboard.user.authenticated.spec.js
```

`docker-modals.user.authenticated.spec.js` must cover:
- logs modal opens for an owned container
- inspect modal opens for an owned container
- remove modal supports cancel and confirm flows
- pressing `Escape` closes the active modal

`docker-dashboard.user.authenticated.spec.js` must cover:
- list page renders `#docker-health-dashboard`
- list page renders `#docker-alerts-panel`
- edit page renders `#docker-live-metrics`
- chart containers render after the stats endpoint returns data
- health badge vocabulary is constrained to `healthy|starting|degraded|unhealthy|unknown`
- alert acknowledge action removes or updates the open alert state

The dashboard suite must assert live cards for:
- CPU
- RAM
- RX/TX network
- last health-check timestamp
- alert count

- [ ] **Step 5: Run both shell and Playwright validations**

Run:

```bash
bash test/test_actions.sh
bash test/test_json_listing.sh
bash test/test_docker_user_actions.sh
npm run playwright:test -- --project=chromium-anonymous
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --project=chromium-docker-user-authenticated
PLAYWRIGHT_ENV_FILE=.env.playwright.local PLAYWRIGHT_ADMIN_PASSWORD='...' npm run playwright:test -- --project=chromium-admin-authenticated
```

If local Docker is unavailable, still run:
- shell syntax checks
- `npm run playwright:test -- --list`

and document that full runtime Docker validation moved to the sydlocal closeout host.

---

## Task 13: Validate And Close Out Against sydlocal.jackpridham.com

**Files:**
- Create: `.docs/validation/sydlocal-docker-e2e-closeout.md`
- Modify: `/home/jackpridham/Work/vortex-scripts/Servers/pve01.jackpridham.com/sydlocal.jackpridham.com/README.md`

- [ ] **Step 1: Stage and apply the runtime overlay to the sydlocal host**

Use the host documented in `/home/jackpridham/Work/vortex-scripts/Servers/pve01.jackpridham.com/sydlocal.jackpridham.com/README.md` and always connect by internal IP:

```bash
export TARGET_HOST="192.168.100.100"
export TARGET_SSH="debian@${TARGET_HOST}"
export DEPLOY_COMMIT="$(git rev-parse --short HEAD)"
export DEPLOY_DATE="$(date -u +%F)"

ssh "$TARGET_SSH" 'rm -rf /tmp/vortex-vesta-overlay && mkdir -p /tmp/vortex-vesta-overlay'
rsync -a bin/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/bin/"
rsync -a func/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/func/"
rsync -a web/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/web/"
rsync -a install/debian/13/templates/web/nginx/vx-proxy.tpl "$TARGET_SSH:/tmp/vortex-vesta-overlay/vx-proxy.tpl"
rsync -a install/debian/13/templates/web/nginx/vx-proxy.stpl "$TARGET_SSH:/tmp/vortex-vesta-overlay/vx-proxy.stpl"

ssh "$TARGET_SSH" "sudo DEPLOY_COMMIT='$DEPLOY_COMMIT' DEPLOY_DATE='$DEPLOY_DATE' bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home

test -d /tmp/vortex-vesta-overlay/bin
test -d /tmp/vortex-vesta-overlay/func
test -d /tmp/vortex-vesta-overlay/web
test -f /tmp/vortex-vesta-overlay/vx-proxy.tpl
test -f /tmp/vortex-vesta-overlay/vx-proxy.stpl

rsync -a /tmp/vortex-vesta-overlay/bin/ /usr/local/vesta/bin/
rsync -a /tmp/vortex-vesta-overlay/func/ /usr/local/vesta/func/
rsync -a /tmp/vortex-vesta-overlay/web/ /usr/local/vesta/web/
install -m 0644 /tmp/vortex-vesta-overlay/vx-proxy.tpl /usr/local/vesta/data/templates/web/nginx/vx-proxy.tpl
install -m 0644 /tmp/vortex-vesta-overlay/vx-proxy.stpl /usr/local/vesta/data/templates/web/nginx/vx-proxy.stpl

chown -R root:root /usr/local/vesta/bin /usr/local/vesta/func /usr/local/vesta/web
find /usr/local/vesta/bin -type f -name 'v-*' -exec chmod 755 {} \;
echo "$DEPLOY_COMMIT" > /usr/local/vesta/conf/vortex-vesta-fork-commit
base_version="$(cat /usr/local/vesta/version.txt 2>/dev/null || echo '0.9.9-0-14')"
base_version="${base_version%%+vxapp*}"
echo "${base_version}+vxapp.${DEPLOY_COMMIT}" > /usr/local/vesta/version.txt
echo "$DEPLOY_DATE" > /usr/local/vesta/build_date.txt

apt-mark hold vesta
systemctl restart vesta nginx apache2
EOF
```

Constraints:
- do not use `rsync --delete`
- do not overwrite `/usr/local/vesta/data/users`
- do not SSH to the hostname; use `ssh debian@192.168.100.100`

- [ ] **Step 2: Validate the deployed runtime on sydlocal before E2E**

Run:

```bash
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home

hostname -f
cat /usr/local/vesta/conf/vortex-vesta-fork-commit
cat /usr/local/vesta/version.txt
cat /usr/local/vesta/build_date.txt
apt-mark showhold | grep '^vesta$'

bash -n \
  /usr/local/vesta/func/vx/docker.sh \
  /usr/local/vesta/bin/v-add-docker-container \
  /usr/local/vesta/bin/v-change-docker-container \
  /usr/local/vesta/bin/v-list-docker-containers \
  /usr/local/vesta/bin/v-list-docker-container-stats \
  /usr/local/vesta/bin/v-update-docker-container-health \
  /usr/local/vesta/bin/v-list-docker-container-alerts

php -l /usr/local/vesta/web/list/docker/index.php
php -l /usr/local/vesta/web/add/docker/index.php
php -l /usr/local/vesta/web/edit/docker/index.php
php -l /usr/local/vesta/web/ajax/docker/router.php
php -l /usr/local/vesta/web/ajax/docker/actions/stats.php
php -l /usr/local/vesta/web/ajax/docker/actions/health.php
php -l /usr/local/vesta/web/ajax/docker/actions/alerts.php

test -f /usr/local/vesta/data/templates/web/nginx/vx-proxy.tpl
test -f /usr/local/vesta/data/templates/web/nginx/vx-proxy.stpl
nginx -t
apache2ctl configtest
/usr/local/vesta/bin/v-check-docker-engine json || true
EOF
```

Expected:
- deployed marker matches `git rev-parse --short HEAD`
- `vesta` is still package-held
- remote Bash and PHP syntax checks pass
- nginx and Apache config tests pass

- [ ] **Step 3: Prepare repeatable scratch data and Playwright auth inputs**

Run:

```bash
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home

scratch_pkg="docker-e2e"
scratch_user="dockere2e"
scratch_pass="ChangeMe-123!"
scratch_mail="dockere2e@local.test"
scratch_domain="docker-e2e.local"

if [ -d "$VESTA/data/users/$scratch_user" ]; then
  /usr/local/vesta/bin/v-delete-user "$scratch_user" yes || true
fi
if [ -f "$VESTA/data/packages/${scratch_pkg}.pkg" ]; then
  /usr/local/vesta/bin/v-delete-user-package "$scratch_pkg" || true
fi

tmpdir="$(mktemp -d)"
cp "$VESTA/data/packages/default.pkg" "$tmpdir/${scratch_pkg}.pkg"
if grep -q "^DOCKER_CONTAINERS=" "$tmpdir/${scratch_pkg}.pkg"; then
  sed -i "s/^DOCKER_CONTAINERS=.*/DOCKER_CONTAINERS='2'/" "$tmpdir/${scratch_pkg}.pkg"
else
  echo "DOCKER_CONTAINERS='2'" >> "$tmpdir/${scratch_pkg}.pkg"
fi
/usr/local/vesta/bin/v-add-user-package "$tmpdir" "$scratch_pkg"
rm -rf "$tmpdir"

/usr/local/vesta/bin/v-add-user "$scratch_user" "$scratch_pass" "$scratch_mail" "$scratch_pkg" Docker E2E
ip="$($VESTA/bin/v-list-user-ips "$scratch_user" plain | awk 'NR==1 {print $1}')"
test -n "$ip"
/usr/local/vesta/bin/v-add-web-domain "$scratch_user" "$scratch_domain" "$ip" no none no
EOF

login_secret="$(ssh "$TARGET_SSH" "sudo php -r 'if (file_exists(\"/usr/local/vesta/web/inc/login_url.php\")) { include \"/usr/local/vesta/web/inc/login_url.php\"; echo \$login_url; }' 2>/dev/null" || true)"

cat > .env.playwright.local <<EOF_ENV
PLAYWRIGHT_BASE_URL=https://192.168.100.100:8083
PLAYWRIGHT_LOGIN_SECRET=${login_secret}
PLAYWRIGHT_ADMIN_USER=admin
PLAYWRIGHT_ADMIN_PASSWORD=
PLAYWRIGHT_DOCKER_USER=dockere2e
PLAYWRIGHT_DOCKER_PASSWORD=ChangeMe-123!
EOF_ENV
```

Expected:
- scratch package exists with `DOCKER_CONTAINERS='2'`
- scratch user exists
- scratch domain exists and belongs to the scratch user
- `.env.playwright.local` exists for the sydlocal target
- `PLAYWRIGHT_LOGIN_SECRET` is populated only when the panel uses secret-login gating

- [ ] **Step 4: Run Playwright UI validation against the sydlocal installation**

Use the repo-local harness against the live panel URL:

```bash
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --project=chromium-anonymous
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --project=chromium-docker-user-authenticated
```

Then run the admin-only suite when the real panel admin password is available:

```bash
PLAYWRIGHT_ENV_FILE=.env.playwright.local \
PLAYWRIGHT_ADMIN_PASSWORD='<existing-admin-password>' \
npm run playwright:test -- --project=chromium-admin-authenticated
```

The sydlocal Playwright pass must validate at least:
- login page CSRF token surface
- user shell authentication
- `/list/docker/` empty state or list state
- add-form field contract and validation state
- successful user-owned container creation
- start/stop/restart transitions
- logs/inspect/remove modals
- live dashboard containers for metrics, health, and alerts
- admin Docker navigation and multi-owner view

If admin credentials are intentionally withheld during an implementation pass, still execute the anonymous and real non-admin suites and record the admin suite as pending operator-secret confirmation rather than treating the entire plan as blocked.

- [ ] **Step 5: Validate backend routing, metrics, health, and alerts on sydlocal**

Run:

```bash
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home

/usr/local/vesta/bin/v-list-docker-container dockere2e app json
/usr/local/vesta/bin/v-list-web-domain dockere2e docker-e2e.local json
/usr/local/vesta/bin/v-update-docker-container-health dockere2e app
/usr/local/vesta/bin/v-list-docker-container-health dockere2e app json
/usr/local/vesta/bin/v-update-sys-rrd-docker daily
/usr/local/vesta/bin/v-list-docker-container-stats dockere2e app 5m json
/usr/local/vesta/bin/v-list-docker-container-alerts dockere2e app json || true

grep "DOMAIN='docker-e2e.local'" /usr/local/vesta/data/users/dockere2e/web.conf
grep "NAME='app'" /usr/local/vesta/data/users/dockere2e/docker.conf

curl -H 'Host: docker-e2e.local' http://192.168.100.100/ -I
EOF
```

Expected:
- `docker.conf` and `web.conf` both persist the route relationship
- health command returns one of `healthy|starting|degraded|unhealthy|unknown`
- stats JSON contains `CPU_PCT`, `MEM_MB`, `RX_MBPS`, `TX_MBPS`, and `LATEST`
- the domain proxies through nginx to the user-owned container

- [ ] **Step 6: Capture closeout artifacts and clean up scratch data**

Create `.docs/validation/sydlocal-docker-e2e-closeout.md` and record:
- deployed commit
- panel URL used
- scratch package/user/domain/container names
- Playwright env file used
- exact commands run
- pass/fail results for overlay validation, Playwright anonymous coverage, Playwright non-admin coverage, Playwright admin coverage, routing, metrics, health, alerts, and cleanup
- location of the generated HTML Playwright report when any browser suite was executed
- any deviations from the plan

Then update `/home/jackpridham/Work/vortex-scripts/Servers/pve01.jackpridham.com/sydlocal.jackpridham.com/README.md` with:
- deployed fork commit
- whether Docker user-management E2E passed
- where the closeout report lives

Finally clean up the scratch objects:

```bash
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home

/usr/local/vesta/bin/v-delete-user dockere2e yes || true
/usr/local/vesta/bin/v-delete-user-package docker-e2e || true
EOF
```

---

## Task 14: Commit In Merge-Friendly Slices

- [ ] **Step 1: Commit the backend ownership model**

```bash
git add func/vx/docker.sh func/docker.sh bin/v-*-docker-* \
  bin/v-add-user bin/v-change-user-package bin/v-list-user bin/v-list-users \
  bin/v-update-user-counters bin/v-update-user-stats \
  bin/v-update-sys-rrd bin/v-update-sys-rrd-docker \
  bin/v-list-docker-container-stats bin/v-update-docker-container-health \
  bin/v-list-docker-container-health bin/v-list-docker-container-alerts \
  bin/v-acknowledge-docker-container-alert \
  bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user \
  bin/v-backup-user bin/v-restore-user bin/v-rebuild-user
git commit -m "feat: add user-owned docker container backend"
```

- [ ] **Step 2: Commit the web UI and routing integration**

```bash
git add web/inc/vx_docker.php web/inc/vx_proxy_form.php web/inc/i18n/en.php \
  web/list/docker/index.php web/add/docker/index.php web/edit/docker/index.php \
  web/start/docker/index.php web/stop/docker/index.php web/restart/docker/index.php \
  web/delete/docker/index.php web/ajax/docker web/js/pages \
  web/templates/admin web/templates/user web/add/package/index.php web/edit/package/index.php
git commit -m "feat: add docker container UI and monitoring dashboards"
```

- [ ] **Step 3: Commit Playwright harness and UI validation coverage**

```bash
git add .gitignore package.json package-lock.json \
  .env.playwright.example playwright.config.js tests/playwright \
  test/test_docker_user_actions.sh test/test_json_listing.sh test/test_actions.sh
git commit -m "test: add playwright coverage for docker panel flows"
```

- [ ] **Step 4: Commit contracts, docs, and plan artifacts**

```bash
git add .docs/contracts .docs/user-guides .docs/validation \
  .docs/plans/2026-06-27-docker-panel-management.md
git commit -m "docs: finalize docker ownership implementation plan"
```

- [ ] **Step 5: Commit the sydlocal README update in the `vortex-scripts` repo**

After the validation run updates:

```text
/home/jackpridham/Work/vortex-scripts/Servers/pve01.jackpridham.com/sydlocal.jackpridham.com/README.md
```

commit that change from the `vortex-scripts` repository separately so the server documentation does not stay dirty outside this repo.
