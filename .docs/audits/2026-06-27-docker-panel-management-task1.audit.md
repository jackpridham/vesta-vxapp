## Audit Scope

This audit validates Task 1 of [.docs/plans/2026-06-27-docker-panel-management.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed ownership-model files:

- [func/vx/docker.sh](/path/to/vesta-vxapp/func/vx/docker.sh)
- [func/docker.sh](/path/to/vesta-vxapp/func/docker.sh)
- [bin/v-check-docker-engine](/path/to/vesta-vxapp/bin/v-check-docker-engine)
- [bin/v-list-docker-containers](/path/to/vesta-vxapp/bin/v-list-docker-containers)
- [bin/v-list-docker-container](/path/to/vesta-vxapp/bin/v-list-docker-container)
- [bin/v-check-docker-container-owner](/path/to/vesta-vxapp/bin/v-check-docker-container-owner)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task1.audit-input.md](/path/to/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task1.audit-input.md).

## Source Requirements

1. [EXPLICIT] Move Docker-specific state logic into `func/vx/docker.sh` and keep `func/docker.sh` as a thin compatibility shim.
2. [EXPLICIT] Add helper support for managed naming, metadata IO, owner validation, reserved localhost host-port allocation, bind-root creation, and route sync into `web.conf`.
3. [EXPLICIT] Replace host-global Docker listing with owner-aware metadata listing in `bin/v-list-docker-containers [USER] [FORMAT]`.
4. [EXPLICIT] Add `bin/v-list-docker-container USER NAME [FORMAT]`.
5. [EXPLICIT] Add `bin/v-check-docker-container-owner USER NAME`.
6. [CONSTRAINT] Container lookups must resolve by metadata first, then confirm matching `vx.user` and `vx.name` runtime labels.
7. [CONSTRAINT] Validate all touched Bash files with `bash -n`.

## Findings By Plan Section

### Task 1: Define The Ownership Model And Managed Runtime Layout

- `info` | Requirements Auditor | `func/vx/docker.sh` satisfies requirements [1] and [2] by centralizing managed naming, metadata file lookup, record parsing, bind-root creation, reserved-port allocation, owner checks, and proxy-route helpers.
- `info` | Requirements Auditor | `func/docker.sh` satisfies requirement [1] as a thin shim that only sources the Vortex helper.
- `info` | Requirements Auditor | `bin/v-list-docker-containers` satisfies requirement [3] by accepting `[USER] [FORMAT]`, defaulting to admin scope for legacy single-format calls, and listing metadata by owner instead of `docker ps -a`.
- `info` | Requirements Auditor | `bin/v-list-docker-container` and `bin/v-check-docker-container-owner` satisfy requirements [4], [5], and [6] by loading `docker.conf` metadata first and then validating runtime ownership labels when the runtime container exists.
- `info` | YAGNI Auditor | The helper stays within the Task 1 seam and does not pull in create/update/runtime rebuild logic that belongs to later tasks.
- `info` | Assumptions Auditor | The ownership check treats missing runtime containers as metadata-managed records rather than hard failures, which is consistent with the plan's metadata-first source-of-truth model at this stage.

## Requirement Gaps

None.

## Audit Summary

Task 1 is complete against the current plan requirements. The repo now has a dedicated Vortex Docker helper, owner-aware metadata listing commands, and metadata-first ownership checks without reintroducing host-global Docker state as the source of truth.

## Resolved Assumptions

- Legacy `v-list-docker-containers json|plain|csv|shell` usage is preserved by treating a single format argument as admin scope, which avoids an unnecessary CLI break while still landing the new owner-aware signature.
- Runtime label confirmation is enforced for exact container lookups and ownership checks, which are the critical metadata-to-runtime integrity checks introduced by this task.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
