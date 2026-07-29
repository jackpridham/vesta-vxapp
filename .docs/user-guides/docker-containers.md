# Docker Containers

> **Historical legacy panel workflow:** This guide documents the direct
> container field model retained for audit history. The current panel manages
> Docker Compose projects, while the simple add/change compatibility path now
> generates a constrained Compose project.
> Follow the [authoritative status](../status/2026-07-25-compose-orchestration.md)
> and [current Compose project guide](docker-compose-projects.md) for current
> operation.

## Prerequisites And Package Limits

Docker container management is available in the panel at `/list/docker/`, `/add/docker/`, and `/edit/docker/`.

- Docker must be installed and available on the host. If it is not, the list page renders `docker-unavailable-state`.
- Regular users can only manage their own containers. Admin can review all owners on `/list/docker/` and can create or edit within a specific `?user=<name>` scope.
- The package limit is enforced through `DOCKER_CONTAINERS`. When the owner has no remaining slots, the list page renders `docker-quota-reached-state` and the add flow is blocked.
- Route domains offered in `v_route_domain` come from domains already owned by the selected user. The panel does not let you proxy to a domain you do not own.
- Managed bind data is kept under `/home/<user>/docker/<container>/`. `v_container_mounts` should use managed mount names such as `data:/srv/app/data`.

## Creating A Container

Open `/add/docker/?user=<owner>` as admin or `/add/docker/` as the owning user. The create form itself is `docker-create-form`.

Fill these fields exactly as named by the UI:

- `v_container_name`: managed container name. This becomes the owner-scoped panel record.
- `v_container_image`: image reference such as `nginx:stable` or `ghcr.io/example/app:latest`.
- `v_container_command`: optional override command.
- `v_container_env`: environment entries, one per line in the UI, persisted as the managed environment set for the container.
- `v_container_mounts`: managed bind definitions such as `data:/srv/app/data`.
- `v_container_port`: internal container port the panel should publish on localhost.
- `v_route_domain`: optional owned domain to attach immediately.
- `v_route_path`: optional proxy path. Leave `/` or blank for the domain root.
- `v_restart_policy`: restart behavior, typically `unless-stopped`, `always`, `on-failure`, or `no`.
- `v_auto_start`: enable auto-start on rebuild and restart flows.
- `v_healthcheck_type`: health mode, typically `http`, `tcp`, `docker`, or `none`.
- `v_healthcheck_target`: health endpoint or target, such as `http://127.0.0.1:8080/health`.
- `v_healthcheck_interval`: polling interval in seconds.
- `v_cpu_alert_pct`: CPU alert threshold.
- `v_mem_alert_mb`: memory alert threshold in MB.
- `v_net_alert_mbps`: network alert threshold in MB/s.
- `v_alert_email`: enable Docker alert delivery through the existing notification path.

Submit the form with `Add`. If validation fails, the page renders the error text in `docker-form-errors` and keeps your current values in `docker-create-form`.

## Routing A Domain

Domain routing is configured from the same create or edit form.

1. Set `v_route_domain` to an owned web domain.
2. Set `v_route_path` if you want the container behind a sub-path instead of the full domain root.
3. Set `v_container_port` to the port exposed by the application inside the container.
4. Save the form.

After save, the panel stores the route target as a localhost proxy and rebuilds the owned domain configuration. On the edit page, `docker-detail-proxy-target` shows the effective proxy target that the panel generated for the container.

## Reading Charts And Health State

The list page exposes scope-wide status through `docker-health-dashboard` and per-container cards under `docker-list-state`. The edit page shows per-container detail in `docker-live-metrics`.

Use these areas as follows:

- `docker-card-cpu`, `docker-card-mem`, `docker-card-rx`, `docker-card-tx`: rolled-up latest values for the current list scope.
- `docker-card-health-status`: highest-priority health state seen in the visible scope.
- `docker-card-health-updated`: latest recorded health timestamp in the visible scope.
- `docker-card-alert-count`: count of open Docker alerts in the visible scope.
- `docker-chart-cpu`, `docker-chart-mem`, `docker-chart-rx`, `docker-chart-tx`: per-container recent series on the edit page.
- `docker-detail-status`: current runtime state, such as running or stopped.
- `docker-detail-health-status`: current health vocabulary, such as `healthy`, `starting`, `degraded`, `unhealthy`, or `unknown`.
- `docker-detail-health-updated`: last health sample time.

Interpretation guidance:

- `healthy` means the configured health check is passing.
- `starting` means the container is up but still within health warm-up behavior.
- `degraded` or `unhealthy` means check failures or alert thresholds need attention.
- `unknown` usually means no sample exists yet, the health mode is `none`, or the runtime check could not return a usable result.

## Handling Alerts

The list page and edit page both render `docker-alerts-panel`. Open alerts show as rows with ids following `docker-alert-<owner>-<aid>`.

- Review the alert `TITLE`, `MESSAGE`, `STATUS`, `ACK`, and `LAST_SEEN` values in the panel.
- Use `docker-alert-acknowledge` to acknowledge the first open, unacknowledged alert shown by the page.
- If alerts repeat after acknowledgement, check `v_healthcheck_type`, `v_healthcheck_target`, `v_healthcheck_interval`, `v_cpu_alert_pct`, `v_mem_alert_mb`, and `v_net_alert_mbps`.
- If `v_alert_email` is enabled, the alert is also eligible for the standard notification path; alert records are still kept even if email delivery is disabled.

The usual operator sequence is: inspect the failing container, correct the route or runtime issue, then acknowledge the alert once the condition is understood or resolved.

## Viewing Logs And Inspect Output

From the list page, each container card has a `Docker` action that opens the floating modal for that owned container.

The modal exposes:

- `View Docker Logs`
- `Inspect Docker Container`
- `Remove Docker Container`

Use `View Docker Logs` first when the container is restarting, failing health checks, or returning application errors. Use `Inspect Docker Container` when you need the effective runtime configuration, labels, network settings, restart policy, or health information reported directly by Docker.

## Deleting And Restoring A Container

Delete is initiated from `/delete/docker/?container=<name>` or from the list card `delete` action. Deletion removes the managed container record and its runtime container.

Before deleting:

- Review `v_route_domain` and `v_route_path` so you know which domain route will be removed.
- Review `v_container_mounts` so you know which managed bind data belongs to the container.
- Capture `View Docker Logs` or `Inspect Docker Container` output if you need an audit trail.

Restore is handled through the user backup and restore flow, not from a dedicated Docker restore page. To recover a deleted managed container:

1. Restore the user backup that contains the container metadata and managed Docker data.
2. Confirm the restored account includes the container record and any related alert state.
3. Re-open `/list/docker/` or `/edit/docker/?container=<name>` and verify `docker-detail-status`, `docker-detail-health-status`, and `docker-detail-proxy-target`.

If you delete a container without an account backup, the panel does not provide a separate undelete action.
