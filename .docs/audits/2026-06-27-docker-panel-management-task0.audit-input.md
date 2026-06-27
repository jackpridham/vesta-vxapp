## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 0: Define Contracts, Schemas, And UI State Specs Up Front

## Sanitized Section Summaries
### Task 0: Define Contracts, Schemas, And UI State Specs Up Front
- Requires four new contract documents under `.docs/contracts/` covering container schema, monitoring schema, alerts schema, and exact UI states.
- Requires exact field names for create/update specs and persisted Docker metadata, including health and alert keys.
- Requires an explicit monitoring contract for RRD layout, datasource names, JSON response shape, and live polling cadence.
- Requires an explicit Docker alerts contract for `data/users/<user>/docker-alerts.conf`, allowed health states, and notification mapping.
- Requires an exact UI contract for list/add/edit/details state ids, chart ids, alert ids, and POST field names.
- Requires a self-review against later plan tasks so the names `HEALTHCHECK_TYPE`, `HEALTHCHECK_TARGET`, `CPU_ALERT_PCT`, `MEM_ALERT_MB`, `NET_ALERT_MBPS`, `HEALTH_STATUS`, and `docker-alerts.conf` stay consistent.

## Technical Claims
- Docker container metadata persists in `data/users/<user>/docker.conf`.
- Docker alert metadata persists in `data/users/<user>/docker-alerts.conf`.
- Docker metrics history uses `$RRD/docker/<user>_<name>.rrd` with `CPU`, `MEM`, `RX`, and `TX` datasources.
- Docker routing reuses `PROXY_MODE` and `PROXY_TARGET` metadata rather than inventing separate nginx state.

## Sensitive Content Handling
- No sensitive literals detected.
