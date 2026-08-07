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
- When a multi-owner adapter sources `func/main.sh`, assign the conventional
  `user` variable to the resolved owner first if the command relies on
  `USER_DATA`; `func/main.sh` derives that path during sourcing.
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

## Compose Command Pattern

- Put shared orchestration in focused `func/vx/compose/*.sh` modules.
- Keep `bin/v-*-docker-project` commands as thin Vesta-shaped adapters.
- Resolve actor, owner, project, profile, and ownership labels before every
  read or mutation.
- Run canonicalization with controlled Compose environment and apply the
  deny-first policy to rendered JSON.
- Treat `compose.yaml` plus root-owned Vesta metadata as desired state; never
  infer authority from Docker objects.
- Hold the project lock across revision checks, deploy/health/routes, and
  rollback. Do not nest a different project lock target.
- Self-service stage/apply accepts only owner-matched `standard` projects and
  verifies preview ownership, mode, expiry, manifests, digests, and expected
  revision before mutation.
- `admin-approved` is bridge-only in its current profile version. Host
  networking is rejected.
- Retain binds and volumes by default; never use global prune or broad cleanup.
- Read `.docs/contracts/compose-interfaces.md`,
  `.docs/contracts/compose-self-service-deployment.md`, and the matching
  lifecycle, policy, or storage contract before changing public behavior.
  Use `.docs/validation/2026-07-29-compose-production-readiness.md` for the
  current release baseline.
- Keep tenant shell access behind `v-docker`, derived
  `vesta-compose-users` membership, and exact `v-run-user-docker-command`
  sudo. Derive identity from kernel/sudo state, require owner equality and
  `standard`, check package `DOCKER_PROJECTS` live, use bounded stdin, and
  acquire the owner lock before any project lock. Vesta owns automatic
  reconciliation; never grant Docker group/socket, raw Docker, caller
  owner/actor arguments, or direct tenant sudo to existing `v-*` commands.

## Validation

- Run `bash -n` on every touched Bash file.
- Run ShellCheck with source following on changed Compose helpers and adapters.
- Run the focused `test/compose/test-*.sh` suites for the changed contract and
  canonicalize every affected fixture with `docker compose config --format
  json`.
- If a command affects rendered domain or proxy state, inspect the related template and generated config paths.
- If a command changes what PHP pages consume, confirm the corresponding `web/` script still matches the CLI contract.
- Before release or deployment, run the complete sequential gate with
  `test/compose/run-production-readiness.sh`.

## Good Anchors

- `bin/v-add-user`
- `bin/v-add-web-domain`
- `bin/v-list-users`
- `func/main.sh`
- `func/domain.sh`
- `func/db.sh`
- `func/ip.sh`
- `func/vx/compose/main.sh`
- `func/vx/compose/transaction.sh`
- `bin/v-stage-docker-project-preview`
- `bin/v-apply-docker-project-preview`
