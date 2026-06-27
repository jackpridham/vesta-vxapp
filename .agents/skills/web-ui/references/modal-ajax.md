# Modal And AJAX Workflow

## Core Pieces

- Modal containers live in `web/templates/header.html`.
- Frontend behavior lives in `web/js/floating-div.js`.
- AJAX endpoints live in `web/ajax/`.
- Form helpers live in `web/inc/form-elements.php`.
- Authentication and ownership checks are loaded through `web/ajax/include_authentication_check.php`.

## Standard Flow

1. A list template defines `dataset_values[index]` with the endpoint URL, title, and context fields.
2. A button calls `more_button_click(index)`.
3. `more_button_click()` POSTs the dataset and `GLOBAL.TOKEN` to `index.php`.
4. `index.php` validates access and returns the first modal form.
5. The form POSTs to `router.php`.
6. `router.php` includes the matching `actions/*.php` script based on the submitted button.
7. The action script either:
   - returns an immediate result
   - asks for confirmation and preserves state through hidden fields
   - or starts a long-running command with `v-spawn-ajax-process`

## Endpoint Rules

At the top of every AJAX endpoint:

```php
$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['dataset']['domain'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
```

For nested action scripts:

```php
$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['domain'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
```

Add more required parameters before the include when the action depends on them.

## Form Helper Patterns

Common helpers:

- `myvesta_open_form($action)`
- `myvesta_close_form()`
- `myvesta_get_hidden_fields(...)`
- `myvesta_get_element(...)`
- `myvesta_get_disabled_textarea(...)`
- `myvesta_hide_floating_div()`

Use `myvesta_get_hidden_fields()` to preserve:

- the original dataset
- action flags used by `router.php`
- any values collected in earlier modal steps

## Command Execution Rules

- Use `$myvesta_logged_user` for command context.
- Escape every command argument with `escapeshellarg()`.
- Prefer `v-spawn-ajax-process` for anything that can take more than a few seconds.

Example:

```php
$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-install-wordpress "
    .escapeshellarg($domain);
```

## Common Pitfalls

- Forgetting the auth-check include in nested action scripts.
- Forgetting `escapeshellarg()` on one of the command arguments.
- Using `$user` or request values instead of `$myvesta_logged_user`.
- Forgetting to preserve hidden fields through a confirmation step.
- Forgetting `exit;` after emitting modal output.

## Minimum Checklist

- Dataset values defined in the template.
- Button wired to `more_button_click()`.
- Required params declared before auth include.
- `index.php` returns the initial form.
- `router.php` dispatches to the right action.
- Action script uses `$myvesta_logged_user`.
- Long-running work uses `v-spawn-ajax-process`.
- All PHP files lint clean.
