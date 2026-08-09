## Audit Scope

This audit validates Task 2 of [.docs/plans/2026-06-27-docker-panel-management.md](../../.docs/plans/2026-06-27-docker-panel-management.md) against the landed provisioning and lifecycle files:

- [func/vx/docker.sh](../../func/vx/docker.sh)
- [bin/v-add-docker-container](../../bin/v-add-docker-container)
- [bin/v-change-docker-container](../../bin/v-change-docker-container)
- [bin/v-start-docker-container](../../bin/v-start-docker-container)
- [bin/v-stop-docker-container](../../bin/v-stop-docker-container)
- [bin/v-restart-docker-container](../../bin/v-restart-docker-container)
- [bin/v-delete-docker-container](../../bin/v-delete-docker-container)
- [bin/v-list-docker-container-logs](../../bin/v-list-docker-container-logs)
- [bin/v-list-docker-container-inspect](../../bin/v-list-docker-container-inspect)
- [bin/v-sync-docker-container-route](../../bin/v-sync-docker-container-route)
- [bin/v-rebuild-docker-containers](../../bin/v-rebuild-docker-containers)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task2.audit-input.md](../../.docs/audits/2026-06-27-docker-panel-management-task2.audit-input.md).

## Source Requirements

1. [EXPLICIT] Add `bin/v-add-docker-container USER SPEC` and `bin/v-change-docker-container USER NAME SPEC` using the Task 0 spec-file contract.
2. [EXPLICIT] Validate user existence and suspension state, package capacity, owned domains, localhost host-port allocation, bind roots under `/home/$user/docker/$NAME`, runtime labels, metadata persistence, and route sync when `DOMAIN` is set.
3. [EXPLICIT] Convert lifecycle and readback commands to `USER NAME` access and resolve metadata before runtime access.
4. [EXPLICIT] Ensure delete removes linked route state, removes only Vortex-managed bind roots, and frees the allocated port by deleting the metadata record.
5. [EXPLICIT] Add `bin/v-sync-docker-container-route USER NAME` using the existing proxy-option command path.
6. [EXPLICIT] Add `bin/v-rebuild-docker-containers USER|admin` that iterates metadata, confirms runtime state, and reapplies routes when linked domains still exist.
7. [CONSTRAINT] Validate the touched Bash files with `bash -n`.

## Findings By Plan Section

### Task 2: Add User-Owned Provisioning, Update, And Lifecycle Commands

- `info` | Requirements Auditor | The add/change commands satisfy requirements [1] and [2] by loading Task 0 spec files, validating owner/domain/package inputs, deriving managed runtime names and localhost ports, creating bind roots under `/home/$user/docker/$NAME`, persisting Docker metadata, and syncing routes when domains are linked.
- `info` | Requirements Auditor | The lifecycle and readback commands satisfy requirements [3] and [4] by taking `USER NAME`, loading metadata first, verifying runtime labels against the stored `CTN_NAME`, and restricting delete-time filesystem cleanup to the managed bind-root path.
- `info` | Requirements Auditor | `bin/v-sync-docker-container-route` satisfies requirement [5] by reusing `v-change-web-domain-proxy-options` with the expected localhost target shape.
- `info` | Requirements Auditor | `bin/v-rebuild-docker-containers` satisfies requirement [6] by iterating per-user or all-user Docker metadata, refreshing persisted runtime state, and reapplying routes only when linked web domains still exist.
- `info` | YAGNI Auditor | The implementation stays within the requested Task 2 seam and defers package-schema expansion, health sampling, and UI work to their later tasks instead of coupling them into the provisioning commands.
- `info` | Assumptions Auditor | The package-capacity check is wired now and becomes active as soon as Task 3 adds `DOCKER_CONTAINERS` to package data, which keeps Task 2 forward-compatible without inventing a second package source of truth.

## Requirement Gaps

None.

## Audit Summary

Task 2 is complete against the current plan requirements. The repo now has spec-file based managed-container provisioning, owner-aware lifecycle/readback commands, explicit route sync, and metadata-driven rebuild behavior, all validated with `bash -n`.

## Resolved Assumptions

- A single-format call to the older host-global list command remains handled in Task 1 for backward compatibility, while Task 2 moves the mutating and readback commands to explicit owner-qualified signatures.
- Route deletion is now enforced when linked proxy state exists, resolving the earlier review concern about best-effort proxy cleanup during container delete and domain changes.
- Package-capacity checks are enforced through package data when the key exists, which lines up with the planned Task 3 package-schema rollout instead of introducing temporary duplicate limit state.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
