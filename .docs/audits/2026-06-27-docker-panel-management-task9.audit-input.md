## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 9: Add Metrics, Health, And Alert Pipelines

## Sanitized Section Summaries
### Task 9: Add Metrics, Health, And Alert Pipelines
- Requires a per-container Docker monitoring pipeline built on the repo’s existing RRD conventions, with one RRD per managed container and JSON stats output matching the Docker monitoring schema contract exactly.
- Requires explicit health evaluation and persistence into `docker.conf`, with the list/edit UI consuming the existing health JSON shape rather than inventing new fields.
- Requires file-backed Docker alerts, notification fan-out, and acknowledge support without losing alert history.
- Requires rebuild-time regeneration hooks so Docker monitoring state can be reconstructed from metadata during restore/rebuild flows.

## Technical Claims
- Docker stats are now sourced from per-container RRD files at `$RRD/docker/<user>_<name>.rrd` and exposed through `v-list-docker-container-stats`.
- Health updates now persist `HEALTH_STATUS` and `LAST_HEALTH_AT`, respect `HEALTHCHECK_INTERVAL`, and feed health alerts.
- Docker alerts remain sourced from `data/users/<user>/docker-alerts.conf`, with shell and PHP writers coordinating through a shared lock file.
- Docker monitoring rebuild work now runs only when active Docker metadata exists, not merely because historical empty files remain on disk.

## Sensitive Content Handling
- No sensitive literals detected.
