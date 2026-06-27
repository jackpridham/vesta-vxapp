## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 6: Build The User-Facing Docker CRUD Pages And Admin Oversight Pages

## Sanitized Section Summaries
### Task 6: Build The User-Facing Docker CRUD Pages And Admin Oversight Pages
- Requires the Docker list page to become role-aware so admins can review all managed containers or filter by owner while regular users only see their own containers.
- Requires Docker add/edit/delete/start/stop/restart web controllers, owner-safe AJAX actions, and matching admin/user templates that preserve CSRF and explicit owner scoping.
- Requires Docker forms to use the documented POST-field contract, route-domain selection, health/alert settings, and live dashboard containers without inventing a second proxy-target input.
- Requires list/edit JavaScript and AJAX endpoints that render the documented no-data, health, and alert states while respecting the Task 9 allowance for contract-shaped no-data monitoring payloads.
- Requires PHP lint attempts for touched web files and validation of the touched shell and JavaScript files where toolchains are available.

## Technical Claims
- User-available Docker AJAX actions must validate the selected owner/name pair before logs, inspect, or remove work is allowed to run.
- Admin “All Users” scope must remain distinct from `admin`-owned containers.
- Non-root route-path values are intentionally rejected until the later proxy-routing seam supports them end-to-end.
- Docker engine install visibility depends on install state, while managed metadata remains listable during daemon outages.
- Alert and health/dashboard rendering must treat alert-file and monitoring payload data as untrusted content.

## Sensitive Content Handling
- No sensitive literals detected.
