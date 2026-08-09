## Audit Scope

This audit validates Task 9 of [.docs/plans/2026-06-27-docker-panel-management.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed Docker monitoring, health, and alert pipeline implementation:

- [func/vx/docker.sh](/path/to/vesta-vxapp/func/vx/docker.sh)
- [func/rebuild.sh](/path/to/vesta-vxapp/func/rebuild.sh)
- [bin/v-rebuild-user](/path/to/vesta-vxapp/bin/v-rebuild-user)
- [bin/v-update-sys-rrd](/path/to/vesta-vxapp/bin/v-update-sys-rrd)
- [bin/v-update-sys-rrd-docker](/path/to/vesta-vxapp/bin/v-update-sys-rrd-docker)
- [bin/v-list-docker-container-stats](/path/to/vesta-vxapp/bin/v-list-docker-container-stats)
- [bin/v-update-docker-container-health](/path/to/vesta-vxapp/bin/v-update-docker-container-health)
- [bin/v-list-docker-container-health](/path/to/vesta-vxapp/bin/v-list-docker-container-health)
- [bin/v-list-docker-container-alerts](/path/to/vesta-vxapp/bin/v-list-docker-container-alerts)
- [bin/v-acknowledge-docker-container-alert](/path/to/vesta-vxapp/bin/v-acknowledge-docker-container-alert)
- [web/inc/vx_docker.php](/path/to/vesta-vxapp/web/inc/vx_docker.php)
- [web/ajax/docker/actions/health.php](/path/to/vesta-vxapp/web/ajax/docker/actions/health.php)
- [.docs/contracts/docker-monitoring-schema.md](/path/to/vesta-vxapp/.docs/contracts/docker-monitoring-schema.md)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task9.audit-input.md](/path/to/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task9.audit-input.md).

## Source Requirements

1. [EXPLICIT] Add per-container RRD sampling from `docker stats --no-stream`, one RRD per managed container at `$RRD/docker/<user>_<name>.rrd`, with Docker graphs rendered beside each RRD.
2. [EXPLICIT] Add `v-list-docker-container-stats` with JSON output matching `.docs/contracts/docker-monitoring-schema.md` exactly, including numeric `VALUE` and `LATEST` fields plus supported periods `5m`, `1h`, `1d`, `7d`.
3. [EXPLICIT] Add health sampling and listing commands that persist `HEALTH_STATUS` and `LAST_HEALTH_AT`, evaluating Docker native health first, explicit HTTP/TCP probes second, and `unknown` last.
4. [EXPLICIT] Add Docker alert persistence, notification fan-out, and acknowledge support backed by `data/users/<user>/docker-alerts.conf`.
5. [EXPLICIT] Extend rebuild flows so Docker monitoring files and charts can be regenerated from metadata during rebuild/restore.
6. [CONSTRAINT] Validate touched Bash with `bash -n` and attempt PHP lint on touched PHP adapters.

## Findings By Plan Section

### Task 9: Add Metrics, Health, And Alert Pipelines

- `info` | Requirements Auditor | Requirement [1] is satisfied. The new Docker RRD updater builds one RRD per managed container under `$RRD/docker`, updates CPU/MEM/RX/TX datasources from `docker stats --no-stream`, renders period-specific graphs, and is wired into the global `v-update-sys-rrd` wrapper.
- `info` | Requirements Auditor | Requirement [2] is satisfied. `v-list-docker-container-stats` returns the schema-contract top-level shape with the required period handling, oldest-to-newest series rows, RFC 3339 UTC timestamps, and numeric JSON values for `VALUE` and `LATEST`.
- `info` | Requirements Auditor | Requirement [3] is satisfied. Health updates now persist `HEALTH_STATUS` and `LAST_HEALTH_AT`, respect `HEALTHCHECK_INTERVAL`, and preserve the existing web health payload shape through the thin PHP bridge.
- `info` | Requirements Auditor | Requirement [4] is satisfied. Docker alerts persist in `docker-alerts.conf`, shell and PHP writers coordinate through a shared lock file, new alerts can trigger `v-add-user-notification`, and acknowledge operations mark `ACK='yes'` without deleting alert history.
- `info` | Requirements Auditor | Requirement [5] is satisfied. Rebuild flows now regenerate Docker monitoring state only when active Docker metadata exists, create `docker-alerts.conf` with the correct permissions, ensure `$RRD/docker` exists, and regenerate the per-period Docker charts.
- `info` | Validation Auditor | Requirement [6] is partially evidenced. `bash -n` passed for `func/vx/docker.sh`, `func/rebuild.sh`, `bin/v-rebuild-user`, `bin/v-update-sys-rrd`, `bin/v-update-sys-rrd-docker`, `bin/v-list-docker-container-stats`, `bin/v-update-docker-container-health`, `bin/v-list-docker-container-health`, `bin/v-list-docker-container-alerts`, and `bin/v-acknowledge-docker-container-alert`. PHP lint could not run because `php` is not installed in this environment.
- `info` | Review Auditor | Task 9 passed spec review and then cleared code-quality review after follow-up fixes for rebuild gating, alert write coordination, health interval enforcement, and the PHP acknowledge-path lockfile read regression.

## Requirement Gaps

None in the landed Task 9 implementation. Remaining evidence gaps are environmental: `php` is not installed for PHP lint, and `rrdtool` is not installed here for end-to-end runtime execution of the new graph pipeline.

## Audit Summary

Task 9 is complete against the current plan requirements. The repo now has a per-container Docker monitoring pipeline with RRD-backed metrics, explicit health persistence, file-backed alerts plus acknowledgement, and rebuild-time regeneration from Docker metadata.

## Resolved Assumptions

- Docker rebuild work should key off active Docker metadata, not the mere existence of stale empty files or directories.
- Alert updates and web acknowledgements need a shared lock primitive to avoid losing writes under concurrent cron/UI activity.
- `HEALTHCHECK_INTERVAL` is part of the monitoring contract and therefore must gate actual probe execution, even when the edit page polls more frequently.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
