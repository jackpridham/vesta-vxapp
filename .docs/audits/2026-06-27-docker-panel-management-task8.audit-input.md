## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 8: Reuse Existing vx-proxy Web-Domain Routing Instead Of Inventing New Nginx State

## Sanitized Section Summaries
### Task 8: Reuse Existing vx-proxy Web-Domain Routing Instead Of Inventing New Nginx State
- Requires Docker routes to keep using the existing web-domain `PROXY_*` fields and `vx-proxy` rendering path rather than introducing a second nginx-routing state model.
- Requires guardrails in the existing web-domain edit flow so an active Docker-owned route stays owned by the Docker page, with an explicit refusal message when a user attempts to change it from the web-domain form.
- Requires rebuild and recovery behavior to keep treating `data/users/<user>/docker.conf` as the Docker routing source of truth and to reapply routes through `bin/v-sync-docker-container-route`.

## Technical Claims
- A Docker-linked domain is only treated as locked when the live web-domain proxy record still matches the Docker metadata route contract.
- The web-domain edit flow refuses Docker-owned proxy mutations before any other domain mutations run.
- `bin/v-change-web-domain-proxy-options` refuses manual proxy mutations on active Docker-owned routes, but still allows `bin/v-sync-docker-container-route` to repair drift from Docker metadata.
- Existing add/rebuild paths continue using the web-domain `PROXY_*` fields and `vx-proxy` templates instead of parsing rendered nginx files.

## Sensitive Content Handling
- No sensitive literals detected.
