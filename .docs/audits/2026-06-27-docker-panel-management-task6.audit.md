## Audit Scope

This audit validates Task 6 of [.docs/plans/2026-06-27-docker-panel-management.md](/home/jackpridham/Work/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed Docker panel controllers, AJAX handlers, helpers, templates, JavaScript, and supporting CLI seams:

- [web/list/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/list/docker/index.php)
- [web/add/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/add/docker/index.php)
- [web/edit/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/edit/docker/index.php)
- [web/start/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/start/docker/index.php)
- [web/stop/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/stop/docker/index.php)
- [web/restart/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/restart/docker/index.php)
- [web/delete/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/delete/docker/index.php)
- [web/ajax/docker/index.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/index.php)
- [web/ajax/docker/router.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/router.php)
- [web/ajax/docker/actions/install.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/install.php)
- [web/ajax/docker/actions/logs.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/logs.php)
- [web/ajax/docker/actions/inspect.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/inspect.php)
- [web/ajax/docker/actions/remove.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/remove.php)
- [web/ajax/docker/actions/stats.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/stats.php)
- [web/ajax/docker/actions/health.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/health.php)
- [web/ajax/docker/actions/alerts.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/alerts.php)
- [web/ajax/docker/actions/acknowledge_alert.php](/home/jackpridham/Work/vesta-vxapp/web/ajax/docker/actions/acknowledge_alert.php)
- [web/inc/vx_docker.php](/home/jackpridham/Work/vesta-vxapp/web/inc/vx_docker.php)
- [web/inc/i18n/en.php](/home/jackpridham/Work/vesta-vxapp/web/inc/i18n/en.php)
- [web/js/pages/list_docker.js](/home/jackpridham/Work/vesta-vxapp/web/js/pages/list_docker.js)
- [web/js/pages/edit_docker.js](/home/jackpridham/Work/vesta-vxapp/web/js/pages/edit_docker.js)
- [web/templates/admin/list_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/admin/list_docker.html)
- [web/templates/admin/add_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/admin/add_docker.html)
- [web/templates/admin/edit_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/admin/edit_docker.html)
- [web/templates/user/list_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/user/list_docker.html)
- [web/templates/user/add_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/user/add_docker.html)
- [web/templates/user/edit_docker.html](/home/jackpridham/Work/vesta-vxapp/web/templates/user/edit_docker.html)
- [bin/v-list-docker-container](/home/jackpridham/Work/vesta-vxapp/bin/v-list-docker-container)
- [bin/v-list-docker-containers](/home/jackpridham/Work/vesta-vxapp/bin/v-list-docker-containers)
- [bin/v-change-docker-container](/home/jackpridham/Work/vesta-vxapp/bin/v-change-docker-container)
- [bin/v-delete-docker-container](/home/jackpridham/Work/vesta-vxapp/bin/v-delete-docker-container)
- [bin/v-check-docker-engine](/home/jackpridham/Work/vesta-vxapp/bin/v-check-docker-engine)
- [func/vx/docker.sh](/home/jackpridham/Work/vesta-vxapp/func/vx/docker.sh)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task6.audit-input.md](/home/jackpridham/Work/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task6.audit-input.md).

## Source Requirements

1. [EXPLICIT] Turn the Docker list page into a role-aware page where admins can view all managed containers or filter by owner and regular users only see owned containers.
2. [EXPLICIT] Add Docker create/edit forms and owner-safe lifecycle pages that follow the standard web controller pattern and redirect back to `/list/docker/` on success.
3. [EXPLICIT] Separate admin-only engine installation from user-available logs, inspect, and remove actions, with owner/name-pair validation through `$myvesta_logged_user`.
4. [EXPLICIT] Put the documented routing, health, and alert fields directly in the Docker forms without adding a free-form nginx target field.
5. [EXPLICIT] Render the documented list/edit monitoring and alert state containers, including explicit no-data states and alert acknowledgement controls.
6. [CONSTRAINT] Respect the Task 9 allowance for contract-shaped no-data monitoring payloads until collectors exist.
7. [CONSTRAINT] Validate touched Bash files with `bash -n`, touched JavaScript with `node --check`, and attempt PHP lint for touched PHP files where the toolchain exists.

## Findings By Plan Section

### Task 6: Build The User-Facing Docker CRUD Pages And Admin Oversight Pages

- `info` | Requirements Auditor | Requirements [1] and [2] are satisfied. The Docker list, add, edit, start, stop, restart, and delete controllers are now owner-aware, admins can filter by owner or manage an explicitly selected user, and non-admin users remain scoped to their own container records.
- `info` | Requirements Auditor | Requirement [3] is satisfied. Docker install remains admin-only, while logs/inspect/remove now validate the selected owner/name pair before commands run, and the router/action flow no longer relies on blanket admin gating.
- `info` | Requirements Auditor | Requirements [4] and [5] are satisfied within the current phase boundary. The forms expose the documented Docker POST contract, health/alert controls, route-domain selection, and exact state containers, while the list/edit JavaScript now renders explicit no-data states, owner-safe alerts, and stable summary behavior.
- `info` | Constraints Auditor | Requirement [6] is satisfied. The stats, health, and alerts endpoints remain contract-shaped and ownership-safe, and the UI explicitly treats missing Task 9 collector data as no-data rather than inventing ad hoc payloads.
- `info` | Validation Auditor | Requirement [7] is partially evidenced. `bash -n` passed for the touched shell files, and `node --check` passed for the touched page JavaScript. The requested `php -l` attempts were made for the touched PHP files but failed in this environment because `php` is not installed.
- `info` | Code Quality Auditor | Review findings were closed before task completion: single-container JSON output is now escaped safely, admin “All Users” scope is distinct from `admin` ownership, the dashboard/alerts UI escapes alert content, route cleanup uses the recorded proxy target, summary cards aggregate deterministically, the CLI and web validators share the same route/health/alert bounds, and daemon outages no longer masquerade as “Docker not installed”.
- `info` | Scope Auditor | Non-root Docker route paths are now rejected consistently in both the web form layer and the CLI/spec parser until later proxy-routing work extends the route-sync seam, preventing the panel from silently accepting unsupported path-routing state.

## Requirement Gaps

None in the landed Task 6 implementation. The remaining evidence gap is PHP syntax validation in an environment that has a `php` binary installed.

## Audit Summary

Task 6 is complete against the current plan requirements. The repo now has a role-aware Docker CRUD surface, owner-safe AJAX and lifecycle actions, contract-shaped monitoring/alert endpoints, dedicated admin/user templates, and hardened helper/CLI seams that keep unsupported route-path behavior and malformed metadata from being silently accepted.

## Resolved Assumptions

- Task 9 collectors are still absent, so the Task 6 monitoring endpoints intentionally return documented no-data payloads while preserving the final contract surface.
- The Docker panel now distinguishes install state from daemon availability: install-only actions remain gated by install state, while managed metadata can still be listed during daemon outages.
- Unsupported non-root route paths are rejected consistently rather than being stored as if they were active.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
