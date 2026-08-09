## Audit Scope

This audit validates Task 3 of [.docs/plans/2026-06-27-docker-panel-management.md](/path/to/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed persistence, reporting, and admin-panel files:

- [bin/v-add-user](/path/to/vesta-vxapp/bin/v-add-user)
- [bin/v-change-user-package](/path/to/vesta-vxapp/bin/v-change-user-package)
- [bin/v-list-user-package](/path/to/vesta-vxapp/bin/v-list-user-package)
- [bin/v-update-user-package](/path/to/vesta-vxapp/bin/v-update-user-package)
- [bin/v-list-user](/path/to/vesta-vxapp/bin/v-list-user)
- [bin/v-list-users](/path/to/vesta-vxapp/bin/v-list-users)
- [bin/v-update-user-counters](/path/to/vesta-vxapp/bin/v-update-user-counters)
- [bin/v-update-user-stats](/path/to/vesta-vxapp/bin/v-update-user-stats)
- [func/main.sh](/path/to/vesta-vxapp/func/main.sh)
- [web/add/package/index.php](/path/to/vesta-vxapp/web/add/package/index.php)
- [web/edit/package/index.php](/path/to/vesta-vxapp/web/edit/package/index.php)
- [web/templates/admin/add_package.html](/path/to/vesta-vxapp/web/templates/admin/add_package.html)
- [web/templates/admin/edit_package.html](/path/to/vesta-vxapp/web/templates/admin/edit_package.html)
- [web/templates/admin/list_packages.html](/path/to/vesta-vxapp/web/templates/admin/list_packages.html)
- [web/templates/admin/list_user.html](/path/to/vesta-vxapp/web/templates/admin/list_user.html)
- [web/templates/admin/edit_user.html](/path/to/vesta-vxapp/web/templates/admin/edit_user.html)
- [install/debian/9/packages/default.pkg](/path/to/vesta-vxapp/install/debian/9/packages/default.pkg)
- [install/debian/9/packages/gainsboro.pkg](/path/to/vesta-vxapp/install/debian/9/packages/gainsboro.pkg)
- [install/debian/9/packages/palegreen.pkg](/path/to/vesta-vxapp/install/debian/9/packages/palegreen.pkg)
- [install/debian/9/packages/slategrey.pkg](/path/to/vesta-vxapp/install/debian/9/packages/slategrey.pkg)
- [install/debian/10/packages/default.pkg](/path/to/vesta-vxapp/install/debian/10/packages/default.pkg)
- [install/debian/11/packages/default.pkg](/path/to/vesta-vxapp/install/debian/11/packages/default.pkg)
- [install/debian/12/packages/default.pkg](/path/to/vesta-vxapp/install/debian/12/packages/default.pkg)
- [install/debian/13/packages/default.pkg](/path/to/vesta-vxapp/install/debian/13/packages/default.pkg)
- [example-of-linux-root-folder/usr/local/vesta/data/packages/default.pkg](/path/to/vesta-vxapp/example-of-linux-root-folder/usr/local/vesta/data/packages/default.pkg)
- [example-of-linux-root-folder/usr/local/vesta/data/users/admin/user.conf](/path/to/vesta-vxapp/example-of-linux-root-folder/usr/local/vesta/data/users/admin/user.conf)
- [example-of-linux-root-folder/usr/local/vesta/data/users/test/user.conf](/path/to/vesta-vxapp/example-of-linux-root-folder/usr/local/vesta/data/users/test/user.conf)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task3.audit-input.md](/path/to/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task3.audit-input.md).

## Source Requirements

1. [EXPLICIT] Add `DOCKER_CONTAINERS` to package data and forms, add `U_DOCKER_CONTAINERS` to user records, and seed both keys in new-user creation.
2. [EXPLICIT] Mirror the new keys into the Debian installer package payloads and the synthetic runtime fixtures under `example-of-linux-root-folder/`.
3. [EXPLICIT] Make package-change, package-list, and package-limit helpers Docker-aware so downgrades are rejected when `U_DOCKER_CONTAINERS > DOCKER_CONTAINERS` unless the existing `FORCE=yes` path is used.
4. [EXPLICIT] Add Docker usage and limits to `v-list-user`, `v-list-users`, `v-update-user-counters`, and `v-update-user-stats`, sourcing Docker counts from `data/users/$user/docker.conf`.
5. [EXPLICIT] Expose Docker quota values on the admin package create/edit/list pages and user list/edit quota summaries through `$_POST['v_docker_containers']`.
6. [CONSTRAINT] Do not add a separate Docker bandwidth collector in this phase; proxied container traffic must remain on the existing web-domain bandwidth path.
7. [CONSTRAINT] Validate the touched Bash files with `bash -n` and lint the touched PHP files with `php -l`.

## Findings By Plan Section

### Task 3: Extend User, Package, Counter, And Stats Persistence

- `info` | Requirements Auditor | Requirements [1] and [2] are satisfied. `bin/v-add-user` now seeds `DOCKER_CONTAINERS` and `U_DOCKER_CONTAINERS`, the package payloads and synthetic runtime fixtures carry `DOCKER_CONTAINERS='0'`, and the example user fixtures carry `U_DOCKER_CONTAINERS='0'`.
- `info` | Requirements Auditor | Requirement [3] is satisfied. `bin/v-change-user-package`, `bin/v-list-user-package`, `bin/v-update-user-package`, and `func/main.sh` all recognize the Docker quota key, and downgrade rejection now covers Docker usage unless `FORCE=yes` is used.
- `info` | Requirements Auditor | Requirement [4] is satisfied. `bin/v-list-user`, `bin/v-list-users`, `bin/v-update-user-counters`, and `bin/v-update-user-stats` now report Docker quotas and usage, with the counter sourced from `data/users/$user/docker.conf`.
- `info` | Requirements Auditor | Requirement [5] is satisfied. The admin package create/edit controllers accept `$_POST['v_docker_containers']`, the package templates expose the input, and package/user list and edit views surface the Docker quota values.
- `info` | Constraints Auditor | Requirement [6] is satisfied. No separate Docker bandwidth collector was introduced, which preserves the planned model where public container traffic is counted through owned proxied web domains.
- `info` | Validation Auditor | The Bash portion of requirement [7] was satisfied with `bash -n` over the touched CLI/helper files, including the Task 3 command set plus the package-list/helper touchpoints.
- `warn` | Validation Auditor | The PHP-lint portion of requirement [7] could not be executed in this environment because `php` is not installed, so syntax evidence for `web/add/package/index.php` and `web/edit/package/index.php` remains an environment-level validation gap rather than an implementation gap.

## Requirement Gaps

None in the landed implementation. The only remaining gap is local validation evidence for the two touched PHP controllers because this workspace does not provide a `php` binary.

## Audit Summary

Task 3 is complete against the implementation requirements. Docker package limits and user counters are now persisted, package changes are quota-aware, counters and stats include Docker usage, and the admin quota surfaces expose the new field. The remaining follow-up is to rerun `php -l` for the two touched controllers in an environment that has PHP installed.

## Resolved Assumptions

- Package data remains the single source of truth for Docker container limits, so Task 2's package-capacity helper now activates without introducing duplicate quota state.
- Docker usage reporting is limited to container counts in this phase; bandwidth accounting remains intentionally attached to the existing proxied web-domain path.
- The web UI uses the same `v_docker_containers` field name on both add and edit package flows, which keeps the admin surface aligned with the CLI quota key.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
