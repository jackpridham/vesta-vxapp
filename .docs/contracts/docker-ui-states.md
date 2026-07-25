# Docker UI State And Markup Contract

> **Historical contract (superseded 2026-07-25):** These states describe the
> direct-container panel. The current Compose UI and compatibility surface are
> defined by [compose-interfaces.md](compose-interfaces.md).

## Scope

This contract defines the exact page-state containers, section ids, card ids, alert ids, chart ids, and POST field names for the Docker panel UI.

It applies to:

- `/list/docker/`
- `/add/docker/`
- `/edit/docker/`

The edit page is also the details view for an existing managed container, so there is no separate `/details/docker/` route in the first implementation.

## Shared ID Rules

- IDs below are exact and must be rendered verbatim.
- Per-container cards must use the pattern `docker-card-<owner>-<name>`.
- Per-alert rows must use the pattern `docker-alert-<owner>-<aid>`.
- The active acknowledge control must use `docker-alert-acknowledge` as its button id.
- Chart containers are singleton ids on the edit/details page.

## List Page States

The list page must always render these top-level state containers, even if some are hidden:

```html
<div id="docker-unavailable-state"></div>
<div id="docker-empty-state"></div>
<div id="docker-quota-reached-state"></div>
<div id="docker-list-state"></div>
<div id="docker-health-dashboard"></div>
<div id="docker-alerts-panel"></div>
```

### List State Semantics

| ID | Meaning | Rendered for |
| --- | --- | --- |
| `docker-unavailable-state` | Docker engine missing, unhealthy, or admin-disabled | admin and user |
| `docker-empty-state` | Docker is available but the current owner-scoped result set is empty | admin and user |
| `docker-quota-reached-state` | create action blocked because `DOCKER_CONTAINERS` package limit is exhausted | user, and admin when managing a specific user at limit |
| `docker-list-state` | populated managed-container list | admin and user |
| `docker-health-dashboard` | summary cards for health and latest metrics | admin and user |
| `docker-alerts-panel` | active/recent Docker alerts | admin and user |

### List Page Child Containers

The list template and JS must use these exact child ids:

```html
<div id="docker-owner-filter"></div>
<div id="docker-list-toolbar"></div>
<div id="docker-list-cards"></div>
<div id="docker-card-cpu"></div>
<div id="docker-card-mem"></div>
<div id="docker-card-rx"></div>
<div id="docker-card-tx"></div>
<div id="docker-card-health-status"></div>
<div id="docker-card-health-updated"></div>
<div id="docker-card-alert-count"></div>
<button id="docker-alert-acknowledge"></button>
```

Per-container list cards must render inside `docker-list-cards` using:

```html
<article id="docker-card-jack-app"></article>
```

Per-alert rows must render inside `docker-alerts-panel` using:

```html
<article id="docker-alert-jack-1"></article>
```

## Add Page States

The add page must render these exact containers:

```html
<div id="docker-create-form"></div>
<div id="docker-form-errors"></div>
<section id="docker-health-settings"></section>
<section id="docker-alert-thresholds"></section>
```

### Add Page Rules

- `docker-create-form` is the required create-form wrapper id.
- The wrapper must contain the page's only create `<form>` element.
- `docker-form-errors` is the only validation-error target for automated checks.
- `docker-health-settings` contains health-check type, target, and interval fields.
- `docker-alert-thresholds` contains CPU, memory, network, and alert-delivery controls.

## Edit And Details Page States

The edit/details page must render these exact containers:

```html
<div id="docker-edit-form"></div>
<div id="docker-form-errors"></div>
<section id="docker-live-metrics"></section>
<section id="docker-health-settings"></section>
<section id="docker-alert-thresholds"></section>
<section id="docker-alerts-panel"></section>
```

### Edit/Details Child Containers

The edit/details page must render these chart and detail ids:

```html
<div id="docker-chart-cpu"></div>
<div id="docker-chart-mem"></div>
<div id="docker-chart-rx"></div>
<div id="docker-chart-tx"></div>
<div id="docker-detail-status"></div>
<div id="docker-detail-health-status"></div>
<div id="docker-detail-health-updated"></div>
<div id="docker-detail-proxy-target"></div>
```

## User/Admin Differences

| Surface | User behavior | Admin behavior |
| --- | --- | --- |
| List source | only owned containers | all managed containers or an explicit owner filter |
| Owner selector | hidden | render `docker-owner-filter` |
| Create/edit owner | fixed to logged-in user | explicit owner only when `?user=<name>` is present |
| Docker engine install controls | never rendered | may render outside this contract's user CRUD states |
| Alerts panel | only owned alerts | owner-aware alerts across visible scope |

## POST Field Contract

Automated form submission and PHP parsing must use these exact POST field names:

```text
v_container_name
v_container_image
v_container_command
v_container_env
v_container_mounts
v_container_port
v_route_domain
v_route_path
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

### POST Field Mapping

| POST field | Persisted/spec field |
| --- | --- |
| `v_container_name` | `NAME` |
| `v_container_image` | `IMAGE` |
| `v_container_command` | `COMMAND` |
| `v_container_env` | `ENV` |
| `v_container_mounts` | `MOUNTS` |
| `v_container_port` | `CONTAINER_PORT` |
| `v_route_domain` | `DOMAIN` |
| `v_route_path` | `ROUTE_PATH` |
| `v_auto_start` | `AUTO_START` |
| `v_restart_policy` | `RESTART_POLICY` |
| `v_healthcheck_type` | `HEALTHCHECK_TYPE` |
| `v_healthcheck_target` | `HEALTHCHECK_TARGET` |
| `v_healthcheck_interval` | `HEALTHCHECK_INTERVAL` |
| `v_cpu_alert_pct` | `CPU_ALERT_PCT` |
| `v_mem_alert_mb` | `MEM_ALERT_MB` |
| `v_net_alert_mbps` | `NET_ALERT_MBPS` |
| `v_alert_email` | `ALERT_EMAIL` |

## Visibility Rules

- `docker-unavailable-state`, `docker-empty-state`, `docker-quota-reached-state`, and `docker-list-state` are mutually exclusive primary list states.
- `docker-health-dashboard` and `docker-alerts-panel` may still render when `docker-list-state` is active.
- `docker-live-metrics` renders on the edit/details page even before the first successful stats poll; empty-chart placeholders live inside the contracted chart ids.
- Alert acknowledge actions must target an alert row with id `docker-alert-<owner>-<aid>` and submit via the control with id `docker-alert-acknowledge`.
- `docker-create-form` and `docker-edit-form` are exact wrapper ids; inner `<form>` elements may use implementation-specific ids so long as the wrapper ids and POST field names stay unchanged.
