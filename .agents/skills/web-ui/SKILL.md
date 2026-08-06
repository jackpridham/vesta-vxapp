---
name: web-ui
description: "Use when changing the web panel in web/, including standard add/list/edit PHP pages, templates, JavaScript, and the modal/AJAX workflow used by floating dialogs and long-running panel actions."
---

# Web UI

Use this skill for `web/` work: PHP pages, templates, JS, AJAX endpoints, and modal-dialog features.

## Standard PHP Page Pattern

For conventional page handlers in `web/add/`, `web/edit/`, `web/list/`, `web/suspend/`, `web/unsuspend/`, and similar:

- Start with:
  - `error_reporting(NULL);`
  - `ob_start();`
  - `$TAB = '...'`
  - `include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");`
- On POST actions, keep the CSRF token check pattern intact.
- Validate required fields, populate `$_SESSION['error_msg']`, and only execute commands when the session has no error.
- Use `escapeshellarg()` for shell-bound values.
- Execute Vesta commands via `VESTA_CMD`.
- End by rendering through `render_page($user, $TAB, 'template_name');`

## AJAX And Modal Workflow

The floating modal system is a first-class pattern, not an exception.

- List templates populate `dataset_values[...]`.
- Trigger buttons call `more_button_click(...)`.
- AJAX features usually use:
  - `index.php` for the initial modal content
  - `router.php` for action dispatch
  - `actions/*.php` for the actual work
- AJAX endpoints must include the authentication check include and define required parameters before loading it.
- Nested action scripts still need authentication checks; they just set the nested-script flag differently.

## Security Rules

- Keep CSRF checks intact.
- Use `escapeshellarg()` for every argument passed to `exec()` or `shell_exec()`.
- Use `$myvesta_logged_user`, not raw request values, when issuing Vesta commands inside AJAX flows.
- Preserve required-parameter and domain-ownership checks for modal actions.
- End AJAX handlers with `exit;` after emitting output.

## Long-Running Work

- Use `v-spawn-ajax-process` for long-running actions instead of blocking the request.
- Pair it with the existing disabled-textarea watcher UI so output streams back into the modal.
- Give each watcher an explicit unique output selector, start it only after the
  target DOM exists, and stop polling on malformed or terminal responses.

## Compose Project Workflows

- Ordinary users may create/update only their own `standard` projects.
  `admin-approved` remains administrator-only.
- Gate Compose controls and mutations on
  `vx_docker_orchestration_ready()`; Docker Engine availability alone is not
  sufficient because Compose v2, `jq`, and `age` are required.
- Use `vx_compose_resolve_mutable_project()` for lifecycle or data mutation.
  Keep `vx_compose_resolve_accessible_project()` for redacted read-only views.
- Preview must be non-mutating. Confirmation posts only the server-issued
  preview token, actor/owner/project/profile facts, digests, and expected
  revision and must match the session record exactly.
- Standard edit preload comes only from the revalidated, redaction-safe
  definition command; never return stored source containing managed-secret
  lines.
- Long-running create/update uses protected short-lived source files or the
  immutable root-owned preview apply command. Never place Compose source,
  secret values, or registry authentication in argv or HTML.
- Route impact may be displayed, but the current advanced editor has no route
  mutation or managed-secret CRUD controls.
- Read `.docs/contracts/compose-interfaces.md` and
  `.docs/contracts/compose-self-service-deployment.md` before changing these
  flows.

## When To Read More

Read [references/modal-ajax.md](references/modal-ajax.md) when:

- you are creating a new modal feature
- you are wiring a new list action into `dataset_values` and `more_button_click()`
- you are adding a router/action flow
- you are touching `web/ajax/`, `web/inc/form-elements.php`, or `web/js/floating-div.js`

## Validation

- Run `php -l` on all touched PHP files.
- Run `node --check` for touched JavaScript and the watcher harness when
  `web/js/floating-div.js` changes.
- If you change modal or AJAX behavior, verify the flow across:
  - template dataset values
  - `more_button_click()`
  - endpoint auth checks
  - the final action handler
- Before a Compose authorization or deployment release, run
  `test/compose/run-production-readiness.sh`.
