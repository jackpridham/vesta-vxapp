# AGENTS.md — vesta-vxapp

## Repo Purpose

- This repository is the source tree for `/usr/local/vesta` on a live host.
- It is a myVesta fork used as the base for Vortex `vesta-vxapp` work.
- Primary code areas:
  - `bin/` -> Vesta CLI commands
  - `func/` -> shared Bash helpers
  - `web/` -> PHP web panel, templates, AJAX handlers, JS
  - `install/` -> installer payloads and default templates for Debian versions
  - `example-of-linux-root-folder/` -> synthetic snapshot of host filesystem paths

## First Step

Before changing code, read the matching local skill in `.agents/skills/`:

- `.agents/skills/runtime-layout/SKILL.md`
  - Use for path mapping, runtime-vs-installer placement, generated vhost paths, and phpMyAdmin/Roundcube path work.
- `.agents/skills/bash-cli/SKILL.md`
  - Use for `bin/` and `func/` changes, rebuild logic, config persistence, and CLI behavior.
- `.agents/skills/web-ui/SKILL.md`
  - Use for `web/` PHP pages, templates, JS, modal dialogs, AJAX flows, and panel security patterns.

The old Cursor rules have been migrated into the local skills above. Use `.agents/skills/` as the single source of agent guidance in this repo.

## Repo Rules

- Treat the repo root as `/usr/local/vesta` on a live host.
- Treat `example-of-linux-root-folder/` as a synthetic `/` from a live host.
- Paths under `example-of-linux-root-folder/usr/local/vesta/...` still map back to `/usr/local/vesta/...` on the server.
- This repo is a fork. Default to a `vx` extension strategy so upstream myVesta changes stay easy to merge and review.
- Preserve existing CLI headers, argument order, and human/json output behavior unless the task explicitly changes them.
- Prefer existing helpers in `func/` over bespoke shell logic.
- Persist state through Vesta config files and helper functions, then rebuild or reload services. Do not treat rendered vhost files as the source of truth.
- For web UI changes, keep CSRF and authentication checks intact, use `escapeshellarg()` for shell arguments, and use `$myvesta_logged_user` in AJAX endpoints.
- If a change affects installer defaults or shipped templates, check whether the relevant `install/debian/<version>/...` trees also need the same change.
- Validate touched Bash with `bash -n`.
- Validate touched PHP with `php -l`.
- If a change affects web templates, rebuild behavior, proxy behavior, or special paths like `/webmail/` or `/phpmyadmin/`, inspect the generated/runtime files implicated by the relevant skill.
- Commit changes before ending the turn.

## Fork Maintenance Rules

- Prefer adding new Vortex logic in `vx`-scoped files instead of spreading custom behavior across upstream files.
- Use `vx` naming for Vortex-specific additions:
  - `func/vx/*.sh` for shared Bash helpers
  - `web/inc/vx_*.php` for shared PHP helpers
  - `vx-*` template names for Vortex-only web/proxy templates
  - `VX_*` or clearly Vortex-scoped config variables where new internal variables are needed
- When upstream files must change, keep them as thin adapters:
  - Add a small include, hook, or function call into `vx` code
  - Avoid embedding large Vortex-only logic blocks directly into upstream functions when the logic can live under `func/vx/` or `web/inc/vx_*.php`
- Do not rename, reformat, or broadly refactor upstream files just to fit Vortex behavior. Keep diffs narrow and intentional.
- Prefer dedicated Vortex commands, helpers, and templates over mutating stock upstream templates in place when the feature is Vortex-specific.
- If a stock template needs Vortex behavior, prefer adding a small hook token or include path and keeping the main template structure close to upstream.
- Keep Vortex persistence logic abstracted from rendered output. Store state in config files and helper layers, then let runtime rendering consume it.
- When adding new CRUD behavior, look for a pattern where:
  - upstream command/controller flow remains recognizable
  - Vortex feature logic is delegated to a `vx` helper/module
  - runtime templates are dedicated `vx-*` variants when behavior differs materially from upstream
- If a change must touch multiple upstream files, explicitly choose the smallest merge-friendly seam rather than duplicating custom logic in several places.
- Mirror any new Vortex runtime template or helper layout into both installer payloads and `example-of-linux-root-folder/` when applicable so the fork remains internally consistent.
- Document new `vx` extension points in repo docs or local skills when they introduce a reusable pattern that future agents should follow.
