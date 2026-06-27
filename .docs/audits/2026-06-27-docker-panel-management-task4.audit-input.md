## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 4: Wire Docker Into User Lifecycle, Suspend/Unsuspend, Backup, Restore, And Delete

## Sanitized Section Summaries
### Task 4: Wire Docker Into User Lifecycle, Suspend/Unsuspend, Backup, Restore, And Delete
- Requires managed Docker containers to participate in user suspend, unsuspend, delete, backup, restore, and generic rebuild flows.
- Requires delete-time cleanup to remove managed runtimes, clear linked proxy state, and remove only the managed Docker metadata and bind-root paths before user deletion.
- Requires backup and restore flows to include Docker metadata files plus managed bind data under `$HOMEDIR/$user/docker`.
- Requires restore to recreate managed runtimes from metadata and reapply proxy routing, while generic rebuild only needs to keep route state aligned.
- Requires Bash syntax validation for the touched shell commands.

## Technical Claims
- Managed Docker metadata lives in `data/users/<user>/docker.conf` and alert state in `data/users/<user>/docker-alerts.conf`.
- Managed bind data remains restricted to `$HOMEDIR/$user/docker/<name>`.
- Legacy `v-restore-user` nine-argument calls remain backward compatible by treating argument 9 as `NOTIFY` and defaulting Docker restore to `yes`.
- The explicit Docker restore selector is exposed through the extended restore form and the queued restore path.

## Sensitive Content Handling
- No sensitive literals detected.
