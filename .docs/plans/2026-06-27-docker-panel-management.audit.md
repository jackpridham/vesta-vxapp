## Audit Scope

This audit validates [.docs/plans/2026-06-27-docker-panel-management.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the user objective and the sanitized snapshot in [.docs/plans/2026-06-27-docker-panel-management.audit-input.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.audit-input.md).

Evidence used:
- current repo files for Docker CLI, user/package/counter state, backup/restore, rebuild, suspend/delete, panel routing, and `vx-proxy`
- subagent audit findings on backend ownership surfaces and web UI/routing seams
- the revised implementation plan itself

## Source Requirements

1. Add full user-facing Docker container creation UI in the Vesta web panel.
2. Add a per-user ownership model so users can manage only their own containers and admins can oversee all managed containers.
3. Cover the full container lifecycle for both roles: create, edit, start, stop, restart, inspect, logs, and delete.
4. Reuse the existing `vx nginx vx-proxy` routing path so user-owned web domains can proxy traffic to user-owned containers.
5. Persist container state in repo-native Vesta data files rather than treating rendered runtime output as source of truth.
6. Enforce package limits and usage counters for Docker ownership.
7. Cover user lifecycle edges that would otherwise break ownership: suspend, unsuspend, delete user, rebuild, backup, and restore.
8. Follow the fork rules by keeping Vortex-specific logic in `vx` seams and mirroring new persisted defaults into the repo’s synthetic/runtime installer data where applicable.

## Findings By Plan Section

### Goal / Architecture / Tech Stack

Covered. The plan now states the correct end state: user-facing provisioning, per-user ownership, admin oversight, and routing through existing `vx-proxy`. It also resolves a major accounting ambiguity by constraining managed writable data to `$HOMEDIR/$user/docker/<container>/` and public traffic to owned web domains.

### Task 1: Ownership Model And Runtime Layout

Covered. The plan defines a concrete ownership registry, concrete labels, a concrete metadata file path, and ownership-aware list/read commands. This closes the current host-global behavior in `func/docker.sh` and `bin/v-*-docker-*`.

### Task 2: Provisioning, Update, Lifecycle, And Route Sync

Covered. The plan defines exact command signatures for create/change/start/stop/restart/delete/logs/inspect plus explicit route-sync and rebuild commands. It also requires domain ownership validation and metadata-first resolution before touching runtime containers.

### Task 3: Package, Counter, Stats, And Installer/Fixture Persistence

Covered after revision. The original narrow plan would have missed package/list helper coverage and mirrored defaults. The revised plan includes `bin/v-list-user-package`, `bin/v-update-user-package`, `func/main.sh`, Debian installer package payloads, and synthetic runtime fixtures, which are all necessary to make Docker limits persist coherently.

### Task 4: Suspend/Delete/Backup/Restore/Rebuild

Covered. The plan addresses the highest-risk lifecycle gaps from the current repo: user suspension, deletion cleanup, backup archive contents, restore rehydration, and user rebuild hooks. It explicitly keeps Docker metadata as the source of truth and rebuilds runtime state from that metadata.

### Task 5: Shared PHP Helpers

Covered. The plan introduces a dedicated `web/inc/vx_docker.php` seam for form parsing and spec generation and keeps proxy parsing in existing helpers rather than duplicating it.

### Task 6: User/Admin Web UI And AJAX

Covered. The plan removes the current hard-admin-only panel behavior, adds role-aware list/add/edit/delete flows, and separates admin-only engine installation from ownership-safe user actions. It also uses the repo’s established AJAX authentication and spawned-process patterns.

### Task 7: Navigation Placement

Covered. The plan keeps the existing admin `Server` placement for host-wide oversight and adds quota-driven visibility in both admin and user panels so the feature is discoverable to non-admin users.

### Task 8: vx-proxy Reuse

Covered. The plan explicitly forbids creating a second routing system and instead treats Docker routing as a producer of existing `PROXY_TARGET` / `PROXY_MODE` state on owned web domains. That matches the current repo seam in `func/vx/proxy.sh`, `web/add/web/index.php`, and `web/edit/web/index.php`.

### Task 9: Regression Coverage

Covered. The plan includes ownership, quota, route wiring, and backup/restore tests, which are the core breakpoints for this feature set.

### Task 10: Commit Strategy

Covered. The plan splits backend ownership work from web UI work and keeps the revised plan artifact tracked, which is consistent with the repo’s merge-friendly extension strategy.

## Requirement Gaps

None found after the final revision.

The current plan comprehensively covers:
- user-facing container creation UI
- per-user ownership and admin oversight
- full lifecycle commands and pages
- routing through the existing `vx nginx vx-proxy` path
- package and counter persistence
- suspend/delete/backup/restore/rebuild edge cases
- Vortex-scoped extension seams and mirrored default-data updates

## Audit Summary

The revised plan is materially different from the original admin-only Docker MVP and now matches the requested end state. It is specific enough to implement without inventing major missing architecture during execution, and it is aligned with the repo’s existing proxy, persistence, and panel patterns.

## Resolved Assumptions

- Docker writable data is constrained to `$HOMEDIR/$user/docker/<container>/` so quota, cleanup, and backup behavior stay inside current account boundaries.
- Public access to containers is expected to arrive through existing web domains and `vx-proxy`, so the plan does not require a second public traffic accounting path.
- The existing `vx-proxy` nginx templates remain the renderer of truth; Docker only supplies proxy metadata.
- Admin oversight is implemented as host-wide managed-container listing plus explicit per-user operations, not as a separate parallel Docker subsystem.

## Open Questions

- Whether non-Debian installer package payloads should also receive `DOCKER_CONTAINERS` defaults is not required by the current repo instructions, which explicitly call out `install/debian/<version>/...`, but it may still be worth deciding during implementation if cross-distro parity matters for this fork.
- If later requirements demand arbitrary host bind paths or Docker named volumes, the current plan intentionally rejects them because they would undermine quota, cleanup, and backup guarantees.

## Sensitive Content Handling

No secrets, credentials, or private runtime data were copied into the audit artifacts. The snapshot and audit only describe repo paths, planned state keys, and command/interface shapes.
