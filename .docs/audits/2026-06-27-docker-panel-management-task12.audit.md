## Audit Scope

This audit validates Task 12 of [.docs/plans/2026-06-27-docker-panel-management.md](/home/jackpridham/Work/vesta-vxapp/.docs/plans/2026-06-27-docker-panel-management.md) against the landed shell regressions, Docker-specific Playwright coverage, helper updates, and fallback validation documentation:

- [test/test_actions.sh](/home/jackpridham/Work/vesta-vxapp/test/test_actions.sh)
- [test/test_docker_user_actions.sh](/home/jackpridham/Work/vesta-vxapp/test/test_docker_user_actions.sh)
- [test/test_json_listing.sh](/home/jackpridham/Work/vesta-vxapp/test/test_json_listing.sh)
- [playwright.config.js](/home/jackpridham/Work/vesta-vxapp/playwright.config.js)
- [tests/playwright/README.md](/home/jackpridham/Work/vesta-vxapp/tests/playwright/README.md)
- [tests/playwright/helpers/panel-auth.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/helpers/panel-auth.js)
- [tests/playwright/helpers/docker-runtime-fixtures.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/helpers/docker-runtime-fixtures.js)
- [tests/playwright/docker-navigation.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-navigation.user.authenticated.spec.js)
- [tests/playwright/docker-access-control.admin.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-access-control.admin.authenticated.spec.js)
- [tests/playwright/docker-empty-state.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-empty-state.user.authenticated.spec.js)
- [tests/playwright/docker-create-form.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-create-form.user.authenticated.spec.js)
- [tests/playwright/docker-lifecycle.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-lifecycle.user.authenticated.spec.js)
- [tests/playwright/docker-modals.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-modals.user.authenticated.spec.js)
- [tests/playwright/docker-dashboard.user.authenticated.spec.js](/home/jackpridham/Work/vesta-vxapp/tests/playwright/docker-dashboard.user.authenticated.spec.js)

The companion sanitized snapshot is [.docs/audits/2026-06-27-docker-panel-management-task12.audit-input.md](/home/jackpridham/Work/vesta-vxapp/.docs/audits/2026-06-27-docker-panel-management-task12.audit-input.md).

## Source Requirements

1. [EXPLICIT] Add shell regression coverage for quota headroom, quota exhaustion, ownership enforcement for lifecycle/delete operations, admin cross-owner management, owner-scoped alert acknowledgement, `PROXY_TARGET` agreement between web-domain and container JSON, and backup/restore recovery of Docker metadata, alerts, bind-root data, and the route link.
2. [EXPLICIT] Add Playwright coverage for user Docker navigation and admin access control, including owner-aware admin rows and owner pivot/filter behavior.
3. [EXPLICIT] Add Playwright coverage for empty state, quota-reached state, the Docker create form, validation-error rendering inside `#docker-form-errors`, successful create redirect back to `/list/docker/`, and lifecycle action-label/state changes without exposing admin-only engine controls.
4. [EXPLICIT] Use the contracted POST field names in the create-form coverage: `v_container_name`, `v_container_image`, `v_container_command`, `v_container_env`, `v_container_mounts`, `v_container_port`, `v_route_domain`, `v_auto_start`, `v_restart_policy`, `v_healthcheck_type`, `v_healthcheck_target`, `v_healthcheck_interval`, `v_cpu_alert_pct`, `v_mem_alert_mb`, `v_net_alert_mbps`, and `v_alert_email`.
5. [EXPLICIT] Add Playwright coverage for Docker logs/inspect/remove modals, Escape-to-close behavior, dashboard presence, live metrics/detail cards, constrained health badge vocabulary, and alert acknowledgement behavior.
6. [EXPLICIT] Run the required shell and Playwright validations, or when local Docker/Vesta runtime execution is unavailable, run shell syntax checks plus Playwright `--list` and document that full runtime validation is deferred to the sydlocal closeout host.
7. [QUALITY] Keep Docker Playwright coverage reliable by ensuring runtime-dependent fixture setup, login flows, and cleanup paths fail loudly on real regressions instead of silently skipping or leaking state.

## Findings By Plan Section

### Task 12: Add Regression Coverage And Docker-Specific Playwright UI Tests

- `info` | Requirements Auditor | Requirement [1] is satisfied. `test/test_docker_user_actions.sh` covers quota headroom, quota exhaustion, wrong-owner denial, admin actor seams, owner-scoped alert acknowledgement, `PROXY_TARGET` agreement, backup artifact contents, restore recovery, and restored route-target matching; `test/test_actions.sh` and `test/test_json_listing.sh` both integrate Docker-aware execution/skip handling.
- `info` | Requirements Auditor | Requirements [2] through [5] are satisfied. The Playwright suite now contains the seven Docker-specific spec files required by the plan and asserts the contracted navigation states, admin owner pivot flow, empty/quota states, create-form field contract, lifecycle actions, modal behavior, dashboard cards, health vocabulary, and alert acknowledgement updates.
- `info` | Requirements Auditor | Requirement [4] is satisfied explicitly in `tests/playwright/docker-create-form.user.authenticated.spec.js`, which enumerates the contracted POST field names and submits the create flow through those exact names.
- `info` | Validation Auditor | Requirement [6] is satisfied through the fallback path documented by the plan. `bash -n test/test_actions.sh test/test_docker_user_actions.sh test/test_json_listing.sh`, `node --check` for the touched Playwright files, `git diff --check`, and `PLAYWRIGHT_ENV_FILE=.env.playwright.example npm run playwright:test -- --list` all passed. The direct shell regression invocations `bash test/test_actions.sh`, `bash test/test_json_listing.sh`, and `bash test/test_docker_user_actions.sh` each returned `SKIP: /etc/profile.d/vesta.sh is unavailable on this host.`, which confirms this environment lacks the local Vesta runtime required for full Docker-backed execution.
- `info` | Review Auditor | The final spec review initially failed only because the fallback validation and sydlocal deferment had not yet been written down at HEAD. The Task 12 closeout artifacts and `tests/playwright/README.md` now record that fallback and the explicit deferment to Task 13.
- `info` | Quality Auditor | Requirement [7] is satisfied after the Task 12 follow-up fixes. The Playwright helper now handles secret-login installs and already-authenticated sessions more safely, destructive same-host fixtures require explicit `PLAYWRIGHT_LOCAL_RUNTIME_TARGET=yes` opt-in before they can touch the local Vesta runtime, dashboard summary/detail waits reject empty-placeholder states and require real chart-series rendering or concrete metric text, health-badge assertions require real badges to exist, lifecycle actions retarget the named container row after each state transition, modal remove flows validate the posted owner/container pair, and same-host create-form cleanup can fall back to direct runtime deletion so disposable containers do not leak when UI cleanup regresses.

## Requirement Gaps

No remaining Task 12 implementation gaps are present in the current tree. The only deferred evidence is full end-to-end Docker/browser execution against a same-host Vesta runtime, which Task 12 explicitly allows to move to the sydlocal closeout host when `/etc/profile.d/vesta.sh` is unavailable locally.

## Audit Summary

Task 12 is complete against the current plan requirements. The repo now has Docker-specific shell regressions, Docker-focused Playwright coverage for the contracted panel states and interactions, supporting helper/runtime-fixture logic, and documented fallback validation evidence for environments that cannot run the live Docker/Vesta flows locally.

## Resolved Assumptions

- The Task 12 validation fallback must be recorded in repo artifacts, not left implicit in command output or reviewer notes.
- Runtime-dependent coverage should only skip when the required seeded host/runtime prerequisites are truly unavailable, not when expected metrics or DOM state regress.
- Same-host destructive Docker fixtures require cleanup paths that can recover even when the panel UI path regresses.

## Open Questions

None.

## Sensitive Content Handling

No secrets or runtime credentials were copied into the audit artifacts.
