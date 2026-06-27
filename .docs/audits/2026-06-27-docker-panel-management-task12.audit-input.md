## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 12: Add Regression Coverage And Docker-Specific Playwright UI Tests

## Sanitized Section Summaries
### Task 12: Add Regression Coverage And Docker-Specific Playwright UI Tests
- Requires shell regressions for Docker ownership, quota, proxy-target alignment, alert acknowledgement scope, and backup/restore coverage.
- Requires Docker-specific Playwright specs for navigation, admin access control, empty/quota states, create-form validation, lifecycle actions, modal flows, dashboard metrics, health badges, and alert acknowledgement.
- Requires create-form assertions to use the contracted Docker POST field names.
- Requires validation evidence for the shell and Playwright harness; when local Docker/Vesta runtime execution is unavailable, the fallback is shell syntax checks plus Playwright `--list`, with full runtime execution deferred to the sydlocal closeout host.

## Technical Claims
- The shell regression suite now includes `test/test_docker_user_actions.sh` plus Docker-aware additions in `test/test_actions.sh` and `test/test_json_listing.sh`.
- The Playwright suite now includes Docker navigation, admin access control, empty/quota state, create-form, lifecycle, modal, and dashboard coverage files under `tests/playwright/`.
- The Playwright helpers now support secret-login/session handling plus explicitly gated same-host runtime fixture seeding and cleanup needed by the Docker UI coverage.
- The README and Task 12 closeout now document the local-runtime fallback validation path and the deferment of full Docker-backed browser execution to Task 13 on sydlocal.

## Sensitive Content Handling
- No secrets copied. Credential variable names are referenced, but no runtime passwords or tokens are included.
