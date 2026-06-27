# Docker Panel Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an admin-facing Docker section to the Vesta panel so administrators can list containers and manage core lifecycle actions from the web UI.

**Architecture:** Add a small Docker CLI surface under `bin/` backed by a shared helper in `func/`, then expose that data through a new admin list page linked from the existing `Server` area plus a modal/AJAX flow for logs, inspect, remove, and Docker installation. Keep the first version intentionally narrow: manage existing containers, do not introduce arbitrary `docker run` creation flows or per-user tenancy rules.

**Tech Stack:** Bash CLI commands, Docker CLI, PHP panel pages, existing myVesta modal/AJAX helpers, `v-spawn-ajax-process`

---

### Task 1: Add Docker CLI Helper And Read Commands

**Files:**
- Create: `func/docker.sh`
- Create: `bin/v-list-docker-containers`
- Create: `bin/v-check-docker-engine`

- [ ] **Step 1: Add the shared Docker helper**

```bash
#!/bin/bash

is_docker_engine_available() {
    command -v docker >/dev/null 2>&1
}

ensure_docker_engine_available() {
    if ! is_docker_engine_available; then
        echo "Docker is not installed"
        exit 11
    fi
}

ensure_docker_container_name_provided() {
    local container_name="$1"
    if [ -z "$container_name" ]; then
        echo "Container name is required"
        exit 12
    fi
}

ensure_docker_container_exists() {
    local container_name="$1"
    if ! docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "Container $container_name does not exist"
        exit 13
    fi
}
```

- [ ] **Step 2: Add the Docker availability command**

```bash
#!/bin/bash
# info: check whether docker engine is available
# options: [FORMAT]

format=${1-shell}

source $VESTA/func/main.sh
source $VESTA/func/docker.sh
source $VESTA/conf/vesta.conf

if is_docker_engine_available; then
    state="yes"
else
    state="no"
fi

case "$format" in
    json)
        echo "{"
        echo "    \"DOCKER_AVAILABLE\": \"$state\""
        echo "}"
        ;;
    *)
        echo "$state"
        ;;
esac

exit 0
```

- [ ] **Step 3: Add the Docker container listing command**

```bash
#!/bin/bash
# info: list docker containers
# options: [FORMAT]

format=${1-shell}

source $VESTA/func/main.sh
source $VESTA/func/docker.sh
source $VESTA/conf/vesta.conf

ensure_docker_engine_available

json_list() {
    local index=1
    echo "{"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$index" -gt 1 ]; then
            echo ","
        fi
        printf '    "%s": %s' "$index" "$line"
        index=$((index + 1))
    done < <(docker ps -a --no-trunc --format '{{json .}}')
    echo
    echo "}"
}

shell_list() {
    docker ps -a --no-trunc --format 'NAME={{.Names}}\tSTATE={{.State}}\tSTATUS={{.Status}}\tIMAGE={{.Image}}\tPORTS={{.Ports}}'
}

case "$format" in
    json) json_list ;;
    *) shell_list ;;
esac

exit 0
```

- [ ] **Step 4: Verify Bash syntax**

Run: `bash -n func/docker.sh bin/v-list-docker-containers bin/v-check-docker-engine`

Expected: no output

- [ ] **Step 5: Commit**

```bash
git add func/docker.sh bin/v-list-docker-containers bin/v-check-docker-engine
git commit -m "feat: add docker listing commands"
```

### Task 2: Add Docker Lifecycle And Readback Commands

**Files:**
- Create: `bin/v-start-docker-container`
- Create: `bin/v-stop-docker-container`
- Create: `bin/v-restart-docker-container`
- Create: `bin/v-delete-docker-container`
- Create: `bin/v-list-docker-container-logs`
- Create: `bin/v-list-docker-container-inspect`

- [ ] **Step 1: Add lifecycle command wrappers**

```bash
#!/bin/bash
# info: start docker container
# options: CONTAINER

container_name="$1"

source $VESTA/func/main.sh
source $VESTA/func/docker.sh
source $VESTA/conf/vesta.conf

ensure_docker_engine_available
ensure_docker_container_name_provided "$container_name"
ensure_docker_container_exists "$container_name"

docker start "$container_name"

exit $?
```

Use the same structure for `stop`, `restart`, and `delete`, replacing the Docker subcommand with `stop`, `restart`, and `rm -f`.

- [ ] **Step 2: Add logs and inspect commands**

```bash
#!/bin/bash
# info: list docker container logs
# options: CONTAINER [TAIL]

container_name="$1"
tail_lines="${2-200}"

source $VESTA/func/main.sh
source $VESTA/func/docker.sh
source $VESTA/conf/vesta.conf

ensure_docker_engine_available
ensure_docker_container_name_provided "$container_name"
ensure_docker_container_exists "$container_name"

docker logs --tail "$tail_lines" "$container_name" 2>&1

exit $?
```

```bash
#!/bin/bash
# info: inspect docker container
# options: CONTAINER

container_name="$1"

source $VESTA/func/main.sh
source $VESTA/func/docker.sh
source $VESTA/conf/vesta.conf

ensure_docker_engine_available
ensure_docker_container_name_provided "$container_name"
ensure_docker_container_exists "$container_name"

docker inspect "$container_name"

exit $?
```

- [ ] **Step 3: Verify Bash syntax**

Run: `bash -n bin/v-start-docker-container bin/v-stop-docker-container bin/v-restart-docker-container bin/v-delete-docker-container bin/v-list-docker-container-logs bin/v-list-docker-container-inspect`

Expected: no output

- [ ] **Step 4: Smoke-check command output shape**

Run: `bin/v-check-docker-engine shell && bin/v-list-docker-containers json | sed -n '1,20p'`

Expected: either `yes` plus JSON container data, or `no` if Docker is absent on the current host

- [ ] **Step 5: Commit**

```bash
git add bin/v-start-docker-container bin/v-stop-docker-container bin/v-restart-docker-container bin/v-delete-docker-container bin/v-list-docker-container-logs bin/v-list-docker-container-inspect
git commit -m "feat: add docker lifecycle commands"
```

### Task 3: Add The Admin Docker List Page Under Server

**Files:**
- Modify: `web/templates/admin/list_services.html`
- Create: `web/list/docker/index.php`
- Create: `web/templates/admin/list_docker.html`

- [ ] **Step 1: Add the Docker link to the existing Server surface**

```php
<td class="step-right">
  <a class="vst" href="/list/docker/"><?=__('Docker')?></a>
</td>
```

Insert it in `web/templates/admin/list_services.html` near the existing CPU / MEM / NET / DISK link so Docker stays under the current admin `Server` area.

- [ ] **Step 2: Add the admin list controller**

```php
<?php
error_reporting(NULL);
$TAB = 'SERVER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

if ($_SESSION['user'] != 'admin') {
    header('Location: /list/user');
    exit;
}

exec(VESTA_CMD."v-check-docker-engine json", $output, $return_var);
$docker_state = json_decode(implode('', $output), true);
if (!is_array($docker_state)) $docker_state = array();
unset($output);

$data = array();
if (!empty($docker_state['DOCKER_AVAILABLE']) && $docker_state['DOCKER_AVAILABLE'] === 'yes') {
    exec(VESTA_CMD."v-list-docker-containers json", $output, $return_var);
    $data = json_decode(implode('', $output), true);
    if (!is_array($data)) $data = array();
    unset($output);
}

render_page($user, $TAB, 'list_docker');
$_SESSION['back'] = $_SERVER['REQUEST_URI'];
```

- [ ] **Step 3: Add the list template**

```php
<script>
  var dataset_values = [];
</script>

<?php foreach ($data as $key => $container) { ++$i; ?>
<script>
dataset_values[<?=$i?>] = {
  'url': '/ajax/docker/index.php',
  'title': '<?=htmlspecialchars($container['Names'], ENT_QUOTES)?>',
  'container_name': '<?=htmlspecialchars($container['Names'], ENT_QUOTES)?>',
  'container_id': '<?=htmlspecialchars($container['ID'], ENT_QUOTES)?>',
  'state': '<?=htmlspecialchars($container['State'], ENT_QUOTES)?>'
};
</script>
<?php } ?>
```

Render each container as an `l-unit` row with:
- name
- image
- status/state
- ports
- mounts
- actions for start/stop, restart, and `more_button_click(...)`

If Docker is unavailable, render a single empty-state unit with a button that opens `/ajax/docker/index.php` for installation.

- [ ] **Step 4: Verify PHP syntax**

Run: `php -l web/list/docker/index.php && php -l web/templates/admin/list_docker.html`

Expected: `No syntax errors detected`

- [ ] **Step 5: Commit**

```bash
git add web/templates/admin/list_services.html web/list/docker/index.php web/templates/admin/list_docker.html
git commit -m "feat: add docker admin list page"
```

### Task 4: Add Docker Modal Actions For Logs, Inspect, Remove, And Install

**Files:**
- Create: `web/ajax/docker/index.php`
- Create: `web/ajax/docker/router.php`
- Create: `web/ajax/docker/actions/logs.php`
- Create: `web/ajax/docker/actions/inspect.php`
- Create: `web/ajax/docker/actions/remove.php`
- Create: `web/ajax/docker/actions/install.php`

- [ ] **Step 1: Add the modal entry point**

```php
<?php
$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");

echo myvesta_open_form('/ajax/docker/router.php');
echo myvesta_get_hidden_fields();
echo myvesta_get_element('button_gray', '', 'docker_logs', __('View Docker Logs'), null, 'width: 300px;', 'add');
echo myvesta_get_element('button_gray', '', 'docker_inspect', __('Inspect Docker Container'), null, 'width: 300px;', 'add');
echo myvesta_get_element('button_gray', '', 'docker_remove', __('Remove Docker Container'), null, 'width: 300px;', 'add');
echo myvesta_close_form();
exit;
```

For the install-empty-state flow, allow the same entry point to render a single `Install Docker` button when `dataset[container_name]` is missing.

- [ ] **Step 2: Add the router**

```php
<?php
$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");

if (!empty($_POST['docker_logs'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/logs.php");
    exit;
}

if (!empty($_POST['docker_inspect'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/inspect.php");
    exit;
}

if (!empty($_POST['docker_remove'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/remove.php");
    exit;
}

if (!empty($_POST['docker_install'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/install.php");
    exit;
}

echo 'No action selected';
exit;
```

- [ ] **Step 3: Add read-only logs and inspect actions**

```php
<?php
$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

$container_name = $_POST['dataset']['container_name'];
$output = shell_exec(
    VESTA_CMD."v-list-docker-container-logs "
    .escapeshellarg($container_name)
    ." 200 2>&1"
);

echo '<b>'.__('Docker container logs').':</b><br /><br />';
echo myvesta_get_disabled_textarea($output, '', true, true, false, '', '', 420);
exit;
```

Use the same pattern for inspect, swapping the command for `v-list-docker-container-inspect`.

- [ ] **Step 4: Add destructive/install actions with spawned output**

```php
<?php
$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

if (isset($_POST['Yes']) == false && isset($_POST['No']) == false) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __('Are you sure you want to remove Docker container %s?', $_POST['dataset']['container_name']).'<br /><br />';
    echo myvesta_get_hidden_fields(array('docker_remove' => '1'));
    echo myvesta_get_element('buttons_confirm', '', 'Yes/No', __('Yes').'/'.__('No'));
    echo myvesta_close_form();
    exit;
}

if (isset($_POST['No'])) {
    myvesta_hide_floating_div();
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-delete-docker-container "
    .escapeshellarg($_POST['dataset']['container_name']);

$hash = trim(shell_exec($cmd));
echo '<b>'.__('Docker remove output').':</b><br /><br />';
echo myvesta_get_disabled_textarea('', '', true, true, true, $myvesta_logged_user, $hash);
exit;
```

Use the same spawned-output pattern for Docker installation, swapping the command to `/usr/local/vesta/bin/v-install-docker-service`.

- [ ] **Step 5: Verify PHP syntax**

Run: `php -l web/ajax/docker/index.php && php -l web/ajax/docker/router.php && php -l web/ajax/docker/actions/logs.php && php -l web/ajax/docker/actions/inspect.php && php -l web/ajax/docker/actions/remove.php && php -l web/ajax/docker/actions/install.php`

Expected: `No syntax errors detected`

- [ ] **Step 6: Commit**

```bash
git add web/ajax/docker/index.php web/ajax/docker/router.php web/ajax/docker/actions/logs.php web/ajax/docker/actions/inspect.php web/ajax/docker/actions/remove.php web/ajax/docker/actions/install.php
git commit -m "feat: add docker modal actions"
```

### Task 5: Add Direct Lifecycle Routes And Final Validation

**Files:**
- Create: `web/start/docker/index.php`
- Create: `web/stop/docker/index.php`
- Create: `web/restart/docker/index.php`
- Modify: `web/templates/admin/list_docker.html`

- [ ] **Step 1: Add direct start/stop/restart handlers**

```php
<?php
error_reporting(NULL);
ob_start();
session_start();
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

if ((!isset($_GET['token'])) || ($_SESSION['token'] != $_GET['token'])) {
    header('location: /login/');
    exit();
}

if ($_SESSION['user'] == 'admin' && !empty($_GET['container'])) {
    $container = escapeshellarg($_GET['container']);
    exec(VESTA_CMD."v-start-docker-container ".$container, $output, $return_var);
    check_return_code($return_var, $output);
}

$back = $_SESSION['back'];
header("Location: ".(!empty($back) ? $back : '/list/docker/'));
exit;
```

Use the same structure for `stop` and `restart`, replacing the command name accordingly.

- [ ] **Step 2: Wire the list template to the routes**

```php
<div class="actions-panel__col actions-panel__<?=$action?> shortcut-s" key-action="href">
  <a href="/<?=$action?>/docker/?container=<?=urlencode($container['Names'])?>&token=<?=$_SESSION['token']?>"><?=__($action)?> <i></i></a>
  <span class="shortcut">&nbsp;S</span>
</div>
<div class="actions-panel__col actions-panel__restart shortcut-r" key-action="href">
  <a href="/restart/docker/?container=<?=urlencode($container['Names'])?>&token=<?=$_SESSION['token']?>"><?=__('restart')?> <i></i></a>
  <span class="shortcut">&nbsp;R</span>
</div>
<div class="actions-panel__col actions-panel__logs" style="background-color: #cae1e5;">
  <a href="javascript:void(0)" onclick="more_button_click(<?=$i?>)"><?=__('Docker')?> <i></i></a>
  <span class="shortcut more">&nbsp;&#8629;</span>
</div>
```

- [ ] **Step 3: Run final validation**

Run: `bash -n func/docker.sh bin/v-list-docker-containers bin/v-check-docker-engine bin/v-start-docker-container bin/v-stop-docker-container bin/v-restart-docker-container bin/v-delete-docker-container bin/v-list-docker-container-logs bin/v-list-docker-container-inspect`

Expected: no output

Run: `php -l web/list/docker/index.php web/ajax/docker/index.php web/ajax/docker/router.php web/ajax/docker/actions/logs.php web/ajax/docker/actions/inspect.php web/ajax/docker/actions/remove.php web/ajax/docker/actions/install.php web/start/docker/index.php web/stop/docker/index.php web/restart/docker/index.php`

Expected: `No syntax errors detected` for all files

- [ ] **Step 4: Manual smoke test**

Run through the admin panel:
- open `/list/docker/`
- verify the Docker tab is visible only to admin
- confirm the page shows an install state when Docker is absent
- confirm running containers show `stop` and stopped containers show `start`
- open the modal and verify logs/inspect output
- remove one disposable test container and confirm streamed output appears

- [ ] **Step 5: Commit**

```bash
git add web/start/docker/index.php web/stop/docker/index.php web/restart/docker/index.php web/templates/admin/list_docker.html
git commit -m "feat: add docker lifecycle routes to panel"
```

## Self-Review

1. Spec coverage:
- Web-panel UI: covered by Tasks 3-5
- Docker lifecycle management: covered by Tasks 2 and 5
- Existing repo patterns: covered by reuse of service routes and modal AJAX helpers

2. Placeholder scan:
- No `TODO`, `TBD`, or deferred implementation markers remain

3. Type consistency:
- Container identifier field is consistently `container_name`
- Docker page remains under the existing `SERVER` tab
- Commands consistently use the `v-*-docker-container` naming scheme

## Execution Handoff

Plan complete and saved to `.docs/plans/2026-06-27-docker-panel-management.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

This request already asked for implementation work in the current turn, so continue with inline execution unless redirected.
