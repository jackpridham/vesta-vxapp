## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 5: Add Shared PHP Helpers For Docker Forms And Ownership-Safe Shell Calls

## Sanitized Section Summaries
### Task 5: Add Shared PHP Helpers For Docker Forms And Ownership-Safe Shell Calls
- Requires a shared Docker helper under `web/inc/` that normalizes Docker form input, builds temp spec payloads, and exposes route-domain options from owned web domains.
- Requires the existing proxy helper seam to stay reusable without duplicating proxy parsing in Docker-specific code.
- Requires explicit Docker/owned-container UI strings to be added to the English language pack.
- Requires PHP lint for the touched helper files when the runtime toolchain is available.

## Technical Claims
- Docker form helpers must use the exact POST-field contract expected by the later Docker CRUD pages.
- The temp spec payload must round-trip safely into the Bash-side Docker spec loader.
- Route-domain helper data must retain enough per-domain metadata for later role-aware Docker forms.
- Proxy helper code should remain proxy-focused rather than depending on Docker-specific helpers.

## Sensitive Content Handling
- No sensitive literals detected.
