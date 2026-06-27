# Docker Container Ownership And Panel Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build complete Docker container management for both users and admins in `vesta-vxapp`, including user-facing container creation UI, per-user ownership and quota enforcement, user/admin lifecycle actions, backup/restore coverage, and domain routing through the existing `vx nginx vx-proxy` flow so a user-owned web domain can proxy traffic to a user-owned container.

**Architecture:** Keep Vortex-specific Docker logic in `vx`-scoped helpers. Persist managed container metadata in `data/users/<user>/docker.conf`, store managed bind data under `$HOMEDIR/$user/docker/<container>/`, publish container ports on `127.0.0.1:<allocated-port>`, and reuse the existing `PROXY_TARGET` / `PROXY_MODE` / `vx-proxy` path already implemented for web domains. Admins get a host-wide overview plus per-user oversight; regular users only see and manage containers they own. Do not support arbitrary host bind paths or unmanaged named volumes in the first complete implementation: keeping writable data under `/home/$user/docker` makes disk quota, cleanup, and backup/restore line up with existing Vesta account boundaries, and routing all public traffic through owned web domains keeps bandwidth accounting on the current nginx/web-domain path instead of inventing a second traffic meter.

**Tech Stack:** Bash CLI commands in `bin/`, Vortex Bash helpers in `func/vx/`, existing Vesta config persistence in `data/users/*`, Docker CLI, PHP panel controllers in `web/`, myVesta modal/AJAX patterns, `v-spawn-ajax-process`, and the existing `func/vx/proxy.sh` / `web/inc/vx_proxy_form.php` routing model.

---

## Task 1: Define The Ownership Model And Managed Runtime Layout

**Files:**
- Create: `func/vx/docker.sh`
- Modify: `func/docker.sh`
- Modify: `bin/v-check-docker-engine`
- Modify: `bin/v-list-docker-containers`
- Create: `bin/v-list-docker-container`
- Create: `bin/v-check-docker-container-owner`

- [ ] **Step 1: Move Docker-specific state logic into a Vortex helper**

Create `func/vx/docker.sh` and keep `func/docker.sh` as a thin adapter that sources it. The helper must own:
- managed name generation: `vx-${user}-${name}`
- ownership labels: `vx.user`, `vx.name`, `vx.managed=yes`
- metadata file IO for `data/users/$user/docker.conf`
- host port allocation from a reserved localhost-only range
- bind-root creation under `$HOMEDIR/$user/docker/$name`
- ownership validation for admin vs regular-user access
- route sync helpers that write `http://127.0.0.1:${HOST_PORT}` into existing `web.conf` proxy keys

Use a concrete metadata shape like this for each record in `data/users/<user>/docker.conf`:

```bash
NAME='app' CTN_NAME='vx-jack-app' IMAGE='ghcr.io/example/app:latest' COMMAND='' \
ENV='PORT=3000||NODE_ENV=production' MOUNTS='data:/srv/app/data||config:/srv/app/config' \
HOST_PORT='21001' CONTAINER_PORT='3000' DOMAIN='app.example.com' ROUTE_PATH='' \
PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:21001' AUTO_START='yes' \
RESTART_POLICY='unless-stopped' STATUS='running' CREATED='2026-06-27 14:00:00'
```

- [ ] **Step 2: Make list/read commands ownership-aware instead of host-global**

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

- [ ] **Step 3: Keep the current non-`vx` Docker helper as a compatibility shim**

`func/docker.sh` should stay small:

```bash
#!/bin/bash
source "$VESTA/func/vx/docker.sh"
```

This keeps existing `bin/v-*-docker-*` command paths stable while moving the real behavior into a merge-friendly Vortex file.

- [ ] **Step 4: Validate the helper and command syntax**

Run:

```bash
bash -n func/vx/docker.sh func/docker.sh \
  bin/v-check-docker-engine bin/v-list-docker-containers \
  bin/v-list-docker-container bin/v-check-docker-container-owner
```

---

## Task 2: Add User-Owned Provisioning, Update, And Lifecycle Commands

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

- [ ] **Step 1: Use spec-file based create/change commands**

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

- [ ] **Step 2: Make every lifecycle command enforce ownership**

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

- [ ] **Step 3: Add rebuild and route-sync commands**

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

- [ ] **Step 4: Validate command syntax**

Run:

```bash
bash -n bin/v-add-docker-container bin/v-change-docker-container \
  bin/v-start-docker-container bin/v-stop-docker-container \
  bin/v-restart-docker-container bin/v-delete-docker-container \
  bin/v-list-docker-container-logs bin/v-list-docker-container-inspect \
  bin/v-rebuild-docker-containers bin/v-sync-docker-container-route
```

---

## Task 3: Extend User, Package, Counter, And Stats Persistence

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

- [ ] **Step 1: Add a package limit and a user counter**

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

- [ ] **Step 2: Make package changes quota-aware**

Update `bin/v-change-user-package`, `bin/v-list-user-package`, `bin/v-update-user-package`, and any limit helpers in `func/main.sh` to recognize the Docker key and reject package downgrades that would leave:

```bash
U_DOCKER_CONTAINERS > DOCKER_CONTAINERS
```

unless the existing `FORCE=yes` path is used.

- [ ] **Step 3: Add Docker counters to user listing and monthly stats**

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

- [ ] **Step 4: Expose Docker limits in package and user admin pages**

Add a `Docker containers` field to:
- package create/edit pages
- package list view
- user list/edit pages where quotas are summarized

The field name should stay consistent with the CLI key:

```php
$_POST['v_docker_containers']
```

- [ ] **Step 5: Validate syntax**

Run:

```bash
bash -n bin/v-add-user bin/v-change-user-package \
  bin/v-list-user bin/v-list-users \
  bin/v-update-user-counters bin/v-update-user-stats

php -l web/add/package/index.php
php -l web/edit/package/index.php
```

---

## Task 4: Wire Docker Into User Lifecycle, Suspend/Unsuspend, Backup, Restore, And Delete

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

- [ ] **Step 1: Stop and resume user-owned containers with account state**

Extend suspend/unsuspend:

```bash
bin/v-suspend-user jack yes
bin/v-unsuspend-user jack yes
```

Rules:
- suspend: stop all owned managed containers and leave metadata intact
- unsuspend: start only containers where `AUTO_START='yes'`
- do not allow a suspended user to create, start, or edit containers

- [ ] **Step 2: Remove owned containers before deleting a user**

Extend `bin/v-delete-user` so it:
1. iterates `data/users/$user/docker.conf`
2. removes each managed container
3. clears any linked `PROXY_TARGET` / `PROXY_MODE` values on owned web domains
4. removes `$HOMEDIR/$user/docker`
5. removes `data/users/$user/docker.conf`

This must happen before `$HOMEDIR/$user` and `$USER_DATA` are deleted.

- [ ] **Step 3: Back up metadata plus managed bind data**

Extend `bin/v-backup-user` and `bin/v-list-user-backups` to include a Docker section that covers:
- `vesta/docker.conf`
- the managed bind-root tree under `$HOMEDIR/$user/docker`

Only managed bind roots under `$HOMEDIR/$user/docker` should be supported. Do not design the feature around arbitrary host bind paths, because those cannot be backed up or safely cleaned up.

- [ ] **Step 4: Restore Docker metadata and then rehydrate runtime**

Extend `bin/v-restore-user` and `bin/v-schedule-user-restore` so restore selectors include Docker metadata/data and the runtime rehydration pass:
1. restore `vesta/docker.conf`
2. restore `$HOMEDIR/$user/docker`
3. recreate each managed container from metadata
4. re-run `bin/v-sync-docker-container-route $user $name`

Concrete restore pass:

```bash
bin/v-restore-user jack jack.2026-06-27_14-00-00.tar yes yes yes yes yes yes no
bin/v-rebuild-docker-containers jack
```

- [ ] **Step 5: Reapply routes during generic user rebuild**

Append a Docker rebuild hook to `bin/v-rebuild-user` and any required helper initialization in `func/rebuild.sh`:

```bash
$BIN/v-rebuild-docker-containers "$user"
```

That keeps container route state aligned whenever the user’s web config is rebuilt.

- [ ] **Step 6: Validate syntax**

Run:

```bash
bash -n bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user \
  bin/v-backup-user bin/v-restore-user bin/v-rebuild-user
```

---

## Task 5: Add Shared PHP Helpers For Docker Forms And Ownership-Safe Shell Calls

**Files:**
- Create: `web/inc/vx_docker.php`
- Modify: `web/inc/vx_proxy_form.php`
- Modify: `web/inc/i18n/en.php`

- [ ] **Step 1: Centralize Docker form parsing**

Create `web/inc/vx_docker.php` with helpers that mirror the existing proxy helper style:
- normalize container name
- build the temp spec file payload
- convert env/mount textarea input into `||`-joined stored strings
- expose role-aware route/domain dropdown options from the user’s existing web domains

Use concrete helper names:

```php
vx_docker_post_value('v_container_name');
vx_docker_env_from_post();
vx_docker_mounts_from_post();
vx_docker_write_spec_file($tmpdir, $spec);
```

- [ ] **Step 2: Keep proxy helpers unchanged except for Docker-specific reuse**

Do not duplicate proxy parsing. Where the Docker forms need to show the eventual proxy target, call the existing proxy helpers and the Docker helper side-by-side.

- [ ] **Step 3: Add explicit strings for owned-container UX**

Add UI strings for:
- `Docker containers`
- `Add Docker container`
- `Container image`
- `Container port`
- `Route domain`
- `Environment variables`
- `Bind mounts`
- `Only domains owned by this user can be routed to this container`
- `Only managed bind roots under /home/<user>/docker are allowed`

- [ ] **Step 4: Validate syntax**

Run:

```bash
php -l web/inc/vx_docker.php
php -l web/inc/vx_proxy_form.php
```

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
- Modify: `web/ajax/docker/actions/remove.php`
- Modify: `web/ajax/docker/actions/logs.php`
- Modify: `web/ajax/docker/actions/inspect.php`
- Modify: `web/ajax/docker/actions/install.php`
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

Do not add free-form nginx target input. The user should choose `container port + route domain`, and the backend should derive the proxy target from the allocated localhost port.

- [ ] **Step 6: Validate syntax**

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

## Task 9: Add Regression Coverage And Operator Validation Steps

**Files:**
- Create: `test/test_docker_user_actions.sh`
- Modify: `test/test_json_listing.sh`
- Modify: `test/test_actions.sh`

- [ ] **Step 1: Cover ownership and quota behavior**

Add shell tests that exercise:
- user can create a container when `DOCKER_CONTAINERS > U_DOCKER_CONTAINERS`
- user cannot create a container when the package limit is exhausted
- user cannot start/stop/delete another user’s container
- admin can inspect and manage another user’s container

- [ ] **Step 2: Cover route wiring**

Add a smoke test that:
1. creates a user-owned web domain
2. creates a user-owned container bound to that domain
3. verifies `v-list-web-domain <user> <domain> json` contains the expected `PROXY_TARGET`
4. verifies `v-list-docker-container <user> <name> json` returns the same derived target

- [ ] **Step 3: Cover backup/restore metadata**

Add a test pass that:
- creates a managed container with bind data under `$HOMEDIR/$user/docker/<name>`
- runs backup
- restores into a clean user state
- verifies `docker.conf`, the bind-root data, and the proxy target all return

- [ ] **Step 4: Run the repo validations**

Run:

```bash
bash test/test_actions.sh
bash test/test_json_listing.sh
bash test/test_docker_user_actions.sh
```

If the local environment does not have Docker available, still run the syntax checks and document that the runtime Docker tests require a host with the Docker engine installed.

---

## Task 10: Commit In Merge-Friendly Slices

- [ ] **Step 1: Commit the backend ownership model**

```bash
git add func/vx/docker.sh func/docker.sh bin/v-*-docker-* \
  bin/v-add-user bin/v-change-user-package bin/v-list-user bin/v-list-users \
  bin/v-update-user-counters bin/v-update-user-stats \
  bin/v-suspend-user bin/v-unsuspend-user bin/v-delete-user \
  bin/v-backup-user bin/v-restore-user bin/v-rebuild-user
git commit -m "feat: add user-owned docker container backend"
```

- [ ] **Step 2: Commit the web UI and routing integration**

```bash
git add web/inc/vx_docker.php web/inc/vx_proxy_form.php web/inc/i18n/en.php \
  web/list/docker/index.php web/add/docker/index.php web/edit/docker/index.php \
  web/start/docker/index.php web/stop/docker/index.php web/restart/docker/index.php \
  web/delete/docker/index.php web/ajax/docker web/templates/admin \
  web/templates/user web/add/package/index.php web/edit/package/index.php
git commit -m "feat: add docker container UI for users and admins"
```

- [ ] **Step 3: Commit tests and plan artifacts**

```bash
git add test/test_docker_user_actions.sh test/test_json_listing.sh test/test_actions.sh \
  .docs/plans/2026-06-27-docker-panel-management.md
git commit -m "docs: finalize docker ownership implementation plan"
```
