---
name: bash-cli
description: "Use when editing Bash commands or helpers in bin/ and func/ in this repo, especially for command structure, validation flow, config persistence, rebuild behavior, and service restarts."
---

# Bash CLI

Use this skill for work in `bin/`, `func/`, and installer shell logic that follows Vesta command patterns.

## Mental Model

- Commands in `bin/` are the public CLI surface.
- Helpers in `func/` carry most of the reusable behavior.
- Vesta data files under `/usr/local/vesta/data/users/<user>/` are the source of truth.
- Rendered service configs are outputs of that state, not the canonical place to persist behavior.
- Web-domain changes usually flow through `web.conf` plus helper functions, then rebuild or restart services.

## Standard Command Shape

Most command files should keep the existing five-part structure:

1. Header with `# info:` and `# options:`
2. `Variable&Function`
3. `Verifications`
4. `Action`
5. `Vesta`

Preserve the established format unless a file already deviates for a good reason.

## Preferred Patterns

- Parse arguments near the top and give optional args explicit defaults.
- Source helpers in the existing Vesta style:
  - `source $VESTA/func/main.sh`
  - domain/db/ip/vx helper includes as needed
  - `source $VESTA/conf/vesta.conf`
- Use Vesta validation helpers rather than ad hoc checks:
  - `check_args`
  - `is_format_valid`
  - `is_system_enabled`
  - `is_object_valid`
  - `is_object_unsuspended`
  - `is_object_new`
  - `is_package_full`
  - `is_password_valid`
- Update persisted state via helpers such as:
  - `update_object_value`
  - `increase_user_value` / `decrease_user_value`
  - object-specific helper functions from `func/`
- Restart services with the existing `v-restart-*` commands and check the result.
- Log successful operations at the end with `log_history` and `log_event`.

## Important Repo-Specific Rules

- Preserve positional CLI compatibility unless the change explicitly introduces new arguments.
- Preserve human-readable output and existing JSON format positions for list/read commands.
- Do not reintroduce the old pattern of `source $USER_DATA/user.conf`; prefer parsing helpers such as `parse_object_kv_list_non_eval`.
- For web-domain behavior, inspect related helpers in `func/domain.sh` and any feature-specific code in `func/vx/` before patching the command itself.
- If a change touches template selection or rendering, reason through:
  - persisted values in `web.conf`
  - helper calls like `add_web_config` / `del_web_config`
  - generated config output in `/home/<user>/conf/web`

## Validation

- Run `bash -n` on every touched Bash file.
- If a command affects rendered domain or proxy state, inspect the related template and generated config paths.
- If a command changes what PHP pages consume, confirm the corresponding `web/` script still matches the CLI contract.

## Good Anchors

- `bin/v-add-user`
- `bin/v-add-web-domain`
- `bin/v-list-users`
- `func/main.sh`
- `func/domain.sh`
- `func/db.sh`
- `func/ip.sh`
