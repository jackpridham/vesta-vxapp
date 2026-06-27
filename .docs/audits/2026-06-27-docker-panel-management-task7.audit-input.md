## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 7: Expose Docker In The User And Admin Panel Navigation

## Sanitized Section Summaries
### Task 7: Expose Docker In The User And Admin Panel Navigation
- Requires the admin Server area to keep the Docker entry while reflecting the Task 6 meaning of the page as managed Docker containers rather than a raw host-container view.
- Requires quota-driven Docker navigation tiles in both admin and user panel shells using the exact `DOCKER_CONTAINERS` and `U_DOCKER_CONTAINERS` panel fields and linking to `/list/docker/`.
- Requires the Docker user/admin template split to remain real after Task 6, not by falling back to serving the admin templates directly for non-admin rendering.
- Requires review gaps found during Task 7 execution to be folded back into the plan and fixed before Task 8 continues.

## Technical Claims
- Docker panel navigation should highlight on `/list/docker/`, `/add/docker/`, and `/edit/docker/`.
- Admin all-users Docker scope must require an explicit owner before the add flow is allowed.
- Admin all-users Docker rendering should group managed containers by owner.
- Shared Docker template markup may be factored into common partials as long as admin and user template entrypoints remain distinct.

## Sensitive Content Handling
- No sensitive literals detected.
