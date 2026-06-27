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

## When To Read More

Read [references/modal-ajax.md](references/modal-ajax.md) when:

- you are creating a new modal feature
- you are wiring a new list action into `dataset_values` and `more_button_click()`
- you are adding a router/action flow
- you are touching `web/ajax/`, `web/inc/form-elements.php`, or `web/js/floating-div.js`

## Validation

- Run `php -l` on all touched PHP files.
- If you change modal or AJAX behavior, verify the flow across:
  - template dataset values
  - `more_button_click()`
  - endpoint auth checks
  - the final action handler
