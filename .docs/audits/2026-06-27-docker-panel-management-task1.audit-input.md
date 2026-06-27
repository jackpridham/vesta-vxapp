## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 1: Define The Ownership Model And Managed Runtime Layout

## Sanitized Section Summaries
### Task 1: Define The Ownership Model And Managed Runtime Layout
- Requires Docker state logic to move into `func/vx/docker.sh` while `func/docker.sh` becomes a thin compatibility shim.
- Requires helper coverage for managed container naming, ownership labels, metadata file IO, reserved localhost port allocation, bind-root creation, owner validation, and proxy-route sync into `web.conf`.
- Requires `bin/v-list-docker-containers` to move from host-global `docker ps` output to metadata-scoped owner-aware output for both admins and regular users.
- Requires new read/check commands: `bin/v-list-docker-container USER NAME [FORMAT]` and `bin/v-check-docker-container-owner USER NAME`.
- Requires metadata-first container resolution followed by runtime label confirmation with `vx.user` and `vx.name`.
- Requires `bash -n` validation for the touched Bash helper and commands.

## Technical Claims
- Managed Docker metadata lives in `data/users/<user>/docker.conf`.
- Proxy route state should be written through the existing `PROXY_MODE` and `PROXY_TARGET` keys in `web.conf`.
- Managed runtime names use `vx-<user>-<name>`.
- Reserved localhost Docker host ports are allocated from a fixed range rather than from rendered runtime state.

## Sensitive Content Handling
- No sensitive literals detected.
