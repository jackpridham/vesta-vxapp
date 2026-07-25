# Docker Screenshot Manifest

> **Historical legacy screenshots:** These targets describe the direct-container
> panel screenshot set. The current Vortex Docker panel is Compose-project
> based and is documented in
> [the operator guide](../../../../docs/container-orchestration.md).

## `user-list-empty.png`

- Page URL: `/list/docker/`
- Login role: regular user with Docker access
- Required seed data: Docker installed and daemon available; no records in the logged-in user's `docker.conf`; package still has at least one `DOCKER_CONTAINERS` slot available
- Exact visible state: `docker-empty-state` visible, `docker-list-state` hidden, no quota warning, add button visible

## `user-list-populated.png`

- Page URL: `/list/docker/`
- Login role: regular user with Docker access
- Required seed data: Docker installed; at least two managed containers owned by the logged-in user; at least one container running with recent stats and one attached `v_route_domain`
- Exact visible state: `docker-list-state`, `docker-health-dashboard`, and `docker-alerts-panel` visible; per-container cards visible under `docker-list-cards`; summary metrics populated

## `user-create-form.png`

- Page URL: `/add/docker/`
- Login role: regular user with Docker access
- Required seed data: Docker installed; package has remaining `DOCKER_CONTAINERS` capacity; at least one owned web domain available for `v_route_domain`
- Exact visible state: `docker-create-form` visible with empty or default values, `docker-form-errors` empty, `docker-health-settings` and `docker-alert-thresholds` both in view

## `user-edit-health-dashboard.png`

- Page URL: `/edit/docker/?container=app`
- Login role: regular user with Docker access
- Required seed data: managed container `app` owned by the logged-in user; container has recent RRD-backed stats; health sampling has written `HEALTH_STATUS` and `LAST_HEALTH_AT`
- Exact visible state: `docker-edit-form` visible with populated container fields; `docker-live-metrics` in view showing `docker-chart-cpu`, `docker-chart-mem`, `docker-chart-rx`, `docker-chart-tx`, `docker-detail-status`, `docker-detail-health-status`, and `docker-detail-health-updated`

## `user-alerts-panel.png`

- Page URL: `/edit/docker/?container=app`
- Login role: regular user with Docker access
- Required seed data: managed container `app` owned by the logged-in user; at least one open alert in `docker-alerts.conf` for that container with `ACK='no'`
- Exact visible state: `docker-alerts-panel` visible with at least one rendered alert row `docker-alert-<owner>-<aid>` and visible `docker-alert-acknowledge` button

## `admin-owner-overview.png`

- Page URL: `/list/docker/`
- Login role: `admin`
- Required seed data: Docker installed; managed containers owned by at least two non-admin users; recent stats available for at least one visible container
- Exact visible state: `docker-list-state` visible in all-owner scope; `docker-owner-filter` visible; grouped owner sections visible under `docker-list-cards`; `docker-health-dashboard` and `docker-alerts-panel` visible

## `admin-docker-unavailable.png`

- Page URL: `/list/docker/`
- Login role: `admin`
- Required seed data: Docker engine unavailable or not installed on the host
- Exact visible state: `docker-unavailable-state` visible, `docker-empty-state` hidden, `docker-list-state` hidden, install action reachable from the page toolbar/modal
