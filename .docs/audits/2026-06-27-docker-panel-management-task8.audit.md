## Audit Scope

This audit validates Task 8 of [.docs/plans/2026-06-27-docker-panel-management.md](../../.docs/plans/2026-06-27-docker-panel-management.md) against the landed Docker/web-domain ownership guard, route-source-of-truth behavior, and recovery-path evidence:

- [web/inc/vx_docker.php](../../web/inc/vx_docker.php)
- [web/edit/web/index.php](../../web/edit/web/index.php)
- [web/templates/admin/edit_web.html](../../web/templates/admin/edit_web.html)
- [web/templates/user/edit_web.html](../../web/templates/user/edit_web.html)
- [web/inc/i18n/en.php](../../web/inc/i18n/en.php)
- [func/vx/docker.sh](../../func/vx/docker.sh)
- [bin/v-change-web-domain-proxy-options](../../bin/v-change-web-domain-proxy-options)
- [bin/v-sync-docker-container-route](../../bin/v-sync-docker-container-route)
- [bin/v-add-web-domain](../../bin/v-add-web-domain)
- [func/vx/proxy.sh](../../func/vx/proxy.sh)
- [bin/v-rebuild-docker-containers](../../bin/v-rebuild-docker-containers)
- [bin/v-rebuild-user](../../bin/v-rebuild-user)
- [bin/v-restore-user](../../bin/v-restore-user)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task8.audit-input.md](../../.docs/audits/2026-06-27-docker-panel-management-task8.audit-input.md).

## Source Requirements

1. [EXPLICIT] Docker routes must keep using the existing web-domain `PROXY_MODE`, `PROXY_TARGET`, `PROXY_PROFILE`, `PROXY_PRESERVE_HOST`, `PROXY_TIMEOUT`, and `PROXY_HEADERS` fields plus `vx-proxy` rendering, rather than introducing a second routing system.
2. [EXPLICIT] When a domain is already linked to a managed Docker container, the Docker page must own the target and the web-domain edit page must refuse conflicting proxy edits with an explicit message or clear the link.
3. [EXPLICIT] The Docker metadata relationship must persist `DOMAIN` and `PROXY_TARGET`.
4. [EXPLICIT] Rebuild and recovery flows must read `data/users/<user>/docker.conf` and call `bin/v-sync-docker-container-route`, never treating rendered nginx files as the source of truth.
5. [CONSTRAINT] Validate touched Bash with `bash -n` and attempt PHP lint on touched PHP/template files.

## Findings By Plan Section

### Task 8: Reuse Existing vx-proxy Web-Domain Routing Instead Of Inventing New Nginx State

- `info` | Requirements Auditor | Requirement [1] is satisfied. Docker route persistence still writes the existing web-domain `PROXY_*` fields, `bin/v-add-web-domain` continues storing those same fields in `web.conf`, and `func/vx/proxy.sh` remains the nginx-rendering path through `vx-proxy.tpl` rather than any new side-channel route store.
- `info` | Requirements Auditor | Requirements [2] and [3] are satisfied. Active Docker-owned routes are detected from Docker metadata plus the current live `web.conf` proxy state, the edit form now shows an explicit Docker ownership notice, and conflicting proxy edits are rejected before any domain mutations run. The backend CLI guard also refuses conflicting manual native-proxy updates on active Docker-owned routes while letting `bin/v-sync-docker-container-route` apply the Docker-owned target from metadata.
- `info` | Requirements Auditor | Requirement [4] is satisfied. The existing rebuild/recovery flows still read `docker.conf` and reapply routes by calling `bin/v-sync-docker-container-route` from Docker rebuild and restore paths, so rendered nginx files are not treated as the routing source of truth.
- `info` | Validation Auditor | Requirement [5] is partially evidenced. `bash -n` passed for `func/vx/docker.sh`, `bin/v-change-web-domain-proxy-options`, and `bin/v-sync-docker-container-route`. The requested `php -l` attempts for the touched PHP/template files remain blocked because `php` is not installed in this environment.
- `info` | Review Auditor | Task 8 passed a dedicated spec review after follow-up fixes for atomic refusal timing, Docker-metadata source-of-truth use, and stale-link detection. The code-quality pass then returned `APPROVED`.

## Requirement Gaps

None in the landed Task 8 implementation. The only remaining evidence gap is PHP syntax validation in an environment that has a `php` binary installed.

## Audit Summary

Task 8 is complete against the current plan requirements. Docker route ownership now stays anchored to Docker metadata and the existing `vx-proxy` web-domain fields, the web edit flow refuses conflicting proxy edits before partial saves can occur, and the backend sync path can still repair live route drift from `docker.conf`.

## Resolved Assumptions

- A Docker route should only lock the web-domain edit flow when the live proxy record still matches the Docker metadata contract, not merely because stale metadata exists.
- The manual native-proxy CLI guard must distinguish between ordinary edits and the Docker sync path so rebuild/recovery flows can repair drift from metadata.
- No new nginx-state parser is required because the existing `PROXY_*` record fields and `vx-proxy` rendering path already provide the needed persistence seam.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
