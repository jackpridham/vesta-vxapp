# Docker Container Ownership And Panel Management Plan Audit Input

**Plan Path:** `.docs/plans/2026-06-27-docker-panel-management.md`
**Snapshot Date:** `2026-06-27`
**Purpose:** Sanitized snapshot for validating whether the implementation plan covers the full user/admin Docker ownership and routing objective.

## Source Requirements

1. Add full user-facing Docker container creation UI in the Vesta web panel.
2. Add a per-user ownership model so users can manage only their own containers and admins can oversee all managed containers.
3. Cover the full container lifecycle for both roles: create, edit, start, stop, restart, inspect, logs, and delete.
4. Reuse the existing `vx nginx vx-proxy` routing path so user-owned web domains can proxy traffic to user-owned containers.
5. Persist container state in repo-native Vesta data files rather than treating rendered runtime output as source of truth.
6. Enforce package limits and usage counters for Docker ownership.
7. Cover user lifecycle edges that would otherwise break ownership: suspend, unsuspend, delete user, rebuild, backup, and restore.
8. Follow the fork rules by keeping Vortex-specific logic in `vx` seams and mirroring new persisted defaults into the repo’s synthetic/runtime installer data where applicable.

## Plan Snapshot

- **Task 1:** Introduces a Vortex Docker helper in `func/vx/docker.sh`, a per-user metadata file `data/users/<user>/docker.conf`, ownership labels, localhost port allocation, and ownership-aware list/read commands.
- **Task 2:** Adds spec-file based create/change commands, converts lifecycle/readback commands to `USER NAME` signatures, and adds route-sync / rebuild commands that call the existing proxy option command.
- **Task 3:** Extends `user.conf`, package data, package/list helpers, counters, stats, admin package pages, Debian installer package payloads, and runtime fixture files with `DOCKER_CONTAINERS` and `U_DOCKER_CONTAINERS`.
- **Task 4:** Extends suspend/unsuspend/delete-user/backup/restore/rebuild flows so managed containers and managed bind-root data are stopped, removed, archived, restored, and re-routed correctly.
- **Task 5:** Adds shared PHP helper code for Docker forms, spec generation, and safe shell invocation while reusing existing proxy helpers.
- **Task 6:** Replaces the admin-only Docker page with role-aware list/add/edit/delete flows, keeps Docker install admin-only, and adds ownership-safe AJAX actions for logs/inspect/remove.
- **Task 7:** Adds Docker visibility to user and admin navigation while preserving the current admin Server placement for host-wide oversight.
- **Task 8:** Explicitly avoids a new nginx system and treats Docker routing as a producer of existing `PROXY_TARGET` / `PROXY_MODE` state on owned web domains.
- **Task 9:** Adds regression coverage for ownership, quota enforcement, route wiring, and backup/restore.
- **Task 10:** Splits implementation into merge-friendly commits.

## Key Assumptions Captured In The Plan

- Writable container data is restricted to `$HOMEDIR/$user/docker/<container>/` so existing home-directory quota and backup boundaries remain valid.
- Public traffic to user-owned containers must flow through owned web domains and `vx-proxy`; direct public host-port publishing is out of scope.
- Existing `func/vx/proxy.sh` and shipped `vx-proxy` templates are retained rather than replaced.
