## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 2: Add User-Owned Provisioning, Update, And Lifecycle Commands

## Sanitized Section Summaries
### Task 2: Add User-Owned Provisioning, Update, And Lifecycle Commands
- Requires new spec-file based create and change commands for managed Docker containers.
- Requires lifecycle and readback commands to move from container-name-only access to `USER NAME` owner-qualified access.
- Requires metadata-first container resolution, runtime label verification, and route cleanup on delete.
- Requires a route-sync command that reuses the existing `v-change-web-domain-proxy-options` path.
- Requires a rebuild command that iterates metadata records for one user or all users and reapplies route state when linked domains still exist.
- Requires `bash -n` validation for the touched command set.

## Technical Claims
- Managed Docker create/update input is passed through temp spec files.
- Managed Docker metadata remains in `data/users/<user>/docker.conf`.
- Runtime labels `vx.user`, `vx.name`, and `vx.managed=yes` are the metadata-to-runtime integrity check.
- Route sync reuses `v-change-web-domain-proxy-options` rather than inventing separate nginx state.

## Sensitive Content Handling
- No sensitive literals detected.
