# AGENTS.md — vesta-vxapp

## Repository

- Repo root maps to `/usr/local/vesta`; `example-of-linux-root-folder/usr/local/vesta/` is its synthetic runtime mirror.
- Main areas: `bin/`, `func/`, `web/`, `install/`, `test/`, and `tests/`.
- Keep Vortex behavior in `vx`-scoped helpers, commands, templates, and PHP includes; keep upstream myVesta changes thin.

## Required Guidance

| Work | Read first |
| --- | --- |
| Runtime paths/installers/templates | `.agents/skills/runtime-layout/SKILL.md` |
| Bash CLI/persistence/lifecycle | `.agents/skills/bash-cli/SKILL.md` |
| PHP/templates/JavaScript/AJAX | `.agents/skills/web-ui/SKILL.md` |
| Compose state/readiness | `docs/container-orchestration.md` |
| Production product gaps | `docs/container-orchestration.md`; evidence in `kb-vxapp/@Reports/@Servers/syd.vortexenterprises.com.au/vesta-compose-orchestration-product-audit/` |
| Compose behavior | Matching `.docs/contracts/compose-*.md` |
| Self-service preview/apply | `.docs/contracts/compose-self-service-deployment.md` |
| Documentation taxonomy | `.docs/README.md` |

## Repository Rules

- Preserve CLI headers, argument order, exit behavior, and human/JSON formats.
- Persist authority in Vesta state and helpers; rendered vhosts and Docker inspect output are evidence.
- Keep CSRF/authentication checks, escape shell arguments, and use `$myvesta_logged_user` in AJAX endpoints.
- Mirror shipped defaults/templates into applicable installer and synthetic-root paths.
- Do not broadly reformat, rename, or refactor upstream files.
- Validate touched Bash with `bash -n`, PHP with `php -l`, JavaScript with `node --check`, and finish with `git diff --check`.
- Commit requested changes before ending.

## Compose Safety

- Desired state is `data/users/<user>/docker-projects/<project>/compose.yaml`; runtime identity is `vx-<user>-<project>`.
- Put shared logic in `func/vx/compose/*.sh`; keep public commands as thin Vesta adapters.
- Canonicalize in a controlled environment, enforce deny-first policy, and verify ownership labels before mutation.
- Ordinary users act only on their own `standard` projects. Privileged profiles remain administrator-only.
- Preserve `v-docker` shell access as package-derived (`DOCKER_PROJECTS`) and automatically reconciled through `vesta-compose-users` plus exact `v-run-user-docker-command` sudo.
- Derive identity from kernel/sudo state, require owner equality and `standard`, bound stdin, and acquire owner lock before project lock.
- Never grant Docker group/socket access, raw Docker, caller owner/actor arguments, or direct tenant sudo to existing `v-*` commands.
- Preview/apply is immutable, digest- and revision-bound, and locked through convergence or rollback.
- Never expose secret/registry values through argv, metadata, environment, logs, UI, audit, or unencrypted backups.
- Keep image trust profile/version bound; adapters use fixed root-owned paths, empty environments, immutable digests, and bounded redacted output.
- Reject privileged mode, Docker sockets, host PID/IPC, devices, arbitrary host paths, unsafe capabilities, and unapproved host networking.
- Retain project data by default; never use global Docker prune, broad cleanup, automatic firewall changes, or route rendering without routes.
- Stage through `debian@192.168.100.100` via `gizmo@192.168.100.16`; audit production through `debian@syd.vortexenterprises.com.au`.
- Production `slave/slave-vxapp` is managed revision 4; preserve its stopped external rollback authority until retention and retirement gates pass.
- Never deploy the withdrawn `vesta-compose-product-corrections-20260731` tag; production uses immutable successor `vesta-compose-product-corrections-20260801` at runtime `8dc0dc9c`.
- Production `slave-vxapp` current/revisions 1–4 use the exact five-field legacy image-evidence shape. Do not broaden that compatibility boundary.
- Production's mount guard is enabled/active and `slave` uses `vxslave-compose`; preserve both unless a separately authorized rollback changes them.
- Keep cross-owner BusinessGUID values in native domain authority; Docker UI may show redacted consumer metadata and header names only.
- Production is read-only without explicit authorization naming target, release, and workload mutation.
- On constrained hosts, use `test/compose/run-production-readiness-limited.sh`; do not run broad ShellCheck or the canonical full gate directly, and never set `VX_READINESS_ALLOW_UNLIMITED=yes` without explicit operator approval.
- Before release/deployment, require the limited launcher—or the canonical gate on an approved unconstrained host—to pass; the launcher runs `test/compose/run-production-readiness.sh` unchanged.
