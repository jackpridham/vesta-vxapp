## Audit Scope

This audit validates Task 4 of [.docs/plans/2026-06-27-docker-panel-management.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed lifecycle, backup, restore, and rebuild files:

- [bin/v-suspend-user](/path/to/vesta-vxapp/bin/v-suspend-user)
- [bin/v-unsuspend-user](/path/to/vesta-vxapp/bin/v-unsuspend-user)
- [bin/v-delete-user](/path/to/vesta-vxapp/bin/v-delete-user)
- [bin/v-backup-user](/path/to/vesta-vxapp/bin/v-backup-user)
- [bin/v-list-user-backups](/path/to/vesta-vxapp/bin/v-list-user-backups)
- [bin/v-list-user-backup](/path/to/vesta-vxapp/bin/v-list-user-backup)
- [bin/v-restore-user](/path/to/vesta-vxapp/bin/v-restore-user)
- [bin/v-schedule-user-restore](/path/to/vesta-vxapp/bin/v-schedule-user-restore)
- [bin/v-rebuild-user](/path/to/vesta-vxapp/bin/v-rebuild-user)
- [bin/v-rebuild-docker-containers](/path/to/vesta-vxapp/bin/v-rebuild-docker-containers)
- [bin/v-start-docker-container](/path/to/vesta-vxapp/bin/v-start-docker-container)
- [bin/v-restart-docker-container](/path/to/vesta-vxapp/bin/v-restart-docker-container)
- [func/rebuild.sh](/path/to/vesta-vxapp/func/rebuild.sh)
- [func/vx/docker.sh](/path/to/vesta-vxapp/func/vx/docker.sh)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task4.audit-input.md](/path/to/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task4.audit-input.md).

## Source Requirements

1. [EXPLICIT] Stop managed user-owned containers during user suspend, keep metadata intact, and on unsuspend start only containers where `AUTO_START='yes'`.
2. [EXPLICIT] Do not allow suspended users to create, start, or edit managed containers.
3. [EXPLICIT] Before deleting a user, remove managed runtimes described in `data/users/$user/docker.conf`, clear linked proxy state on owned domains, remove `$HOMEDIR/$user/docker`, and remove Docker metadata files before `$HOMEDIR/$user` and `$USER_DATA` are deleted.
4. [EXPLICIT] Extend backup and backup-list reporting to include `vesta/docker.conf`, `vesta/docker-alerts.conf`, and managed bind data under `$HOMEDIR/$user/docker`.
5. [EXPLICIT] Extend restore and scheduled-restore flows so Docker metadata/data can be restored, managed runtimes are recreated from metadata, and proxy routes are re-synced.
6. [EXPLICIT] Append a Docker rebuild hook to generic user rebuild so route state stays aligned when user web config is rebuilt.
7. [CONSTRAINT] Keep managed bind-data support limited to `$HOMEDIR/$user/docker`.
8. [CONSTRAINT] Validate the touched shell commands with `bash -n`.

## Findings By Plan Section

### Task 4: Wire Docker Into User Lifecycle, Suspend/Unsuspend, Backup, Restore, And Delete

- `info` | Requirements Auditor | Requirements [1] and [2] are satisfied. User suspend/unsuspend now handles managed containers, `v-start-docker-container` and `v-restart-docker-container` block suspended users, and existing add/change commands already enforced unsuspended-user checks.
- `info` | Requirements Auditor | Requirement [3] is satisfied. `bin/v-delete-user` now removes managed runtimes and matching proxy routes before user home and metadata deletion, and it only removes managed Docker paths under `$HOMEDIR/$user/docker`.
- `info` | Requirements Auditor | Requirement [4] is satisfied. `bin/v-backup-user`, `bin/v-list-user-backups`, and `bin/v-list-user-backup` now persist and report Docker backup coverage, including metadata files and managed bind data.
- `info` | Requirements Auditor | Requirements [5] and [6] are satisfied. `bin/v-restore-user` restores Docker metadata and bind data, performs daemon-availability preflight before destructive cleanup, recreates managed runtimes from metadata, and re-syncs routes; generic rebuild now keeps Docker route/runtime metadata aligned without widening into restore-time runtime creation.
- `info` | Constraints Auditor | Requirement [7] is satisfied. Backup, cleanup, and restore remain scoped to `$HOMEDIR/$user/docker`, and the generic user-dir backup explicitly excludes `docker` to avoid double-handling or arbitrary bind-path support.
- `info` | Validation Auditor | Requirement [8] is satisfied. The touched shell files were validated with `bash -n`, and later fix-up commits also passed `git diff --check`.
- `info` | Assumptions Auditor | The restore CLI ambiguity was resolved safely by preserving legacy nine-argument calls as `NOTIFY`-only and exposing the explicit Docker selector through the extended restore form plus queued restore path.
- `info` | Code Quality Auditor | Review findings from the first code-quality pass were closed before task completion: generic rebuild no longer recreates runtimes, route cleanup is limited to the exact recorded proxy target, restore preflights daemon availability before destructive cleanup, and generic rebuild preserves health metadata.

## Requirement Gaps

None.

## Audit Summary

Task 4 is complete against the current plan requirements. Managed Docker containers now participate in user lifecycle, backup, restore, and rebuild flows without expanding generic rebuild into runtime resurrection, and the restore path now protects existing Docker state with narrower route cleanup plus daemon-availability preflight.

## Resolved Assumptions

- The old `v-restore-user` positional form remains backward compatible by treating a ninth argument as `NOTIFY`, while explicit Docker selection uses the extended form with both `DOCKER` and `NOTIFY`.
- Generic user rebuild is limited to route/runtime metadata alignment; restore-time runtime creation is handled separately through dedicated Docker rehydration logic.
- Docker route cleanup only removes proxy state when the current domain `PROXY_TARGET` matches the specific container record being cleaned up.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
