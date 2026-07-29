# Compose Production-Readiness Documentation Synchronization Plan

**Goal:** Align every active repository overview, operator guide, contract,
user guide, agent instruction, and repository skill with the production-ready
Compose implementation and its 2026-07-29 staging validation.

**Authority:** Use the shipped implementation, current `compose-*` contracts,
the authoritative Compose status, and
`.docs/validation/2026-07-29-compose-production-readiness.md`. Preserve dated
plans, audits, and checkpoint reports as historical evidence.

## Traceability

| Requirement | Documentation surfaces | Validation |
| --- | --- | --- |
| Distinguish production-ready implementation from production promotion | `README.md`, `.docs/README.md`, current guides and status | Docs consistency assertions |
| Record the final release gate and staging evidence | README, operator guide, validation index, local skills | Exact evidence/link checks |
| Keep policy/profile behavior aligned with code | Compose policy, networking, and security contracts; operator guide | Profile JSON and focused docs checks |
| Keep agent guidance concise and executable | `AGENTS.md`, `.agents/skills/` | Path, command, link, and line-count checks |
| Preserve historical evidence | `.docs/plans/`, `.docs/audits/`, legacy guides/contracts | Supersession and taxonomy checks |

## Tasks

- [x] Inventory all Markdown under `README.md`, `AGENTS.md`, `.docs/`,
  `docs/`, and `.agents/skills/`.
- [x] Reconcile active readiness, validation-count, profile, deployment, and
  staging claims against implementation and final validation evidence.
- [x] Update active overviews, guides, contracts, status/index, and skills.
- [x] Extend documentation consistency checks to reject the stale readiness
  and generic administrator host-network claims.
- [x] Validate local links, referenced paths/commands, Markdown structure,
  documentation consistency, Bash syntax for the docs check, and whitespace.
- [x] Review the complete diff, record final documentation evidence, and
  commit the synchronization.

## Closeout evidence

- `bash test/test_compose_docs.sh` passed the complete mutable documentation
  link graph, active readiness/profile assertions, implementation/profile
  alignment, dynamic suite/fixture counts, and legacy supersession checks.
- `bash -n` and warning-level ShellCheck passed for the documentation checker.
- All requested Markdown had balanced fenced blocks and no conflict markers;
  `AGENTS.md` remained at 59 lines.
- Playwright discovery passed with the protected mode-0600 environment and
  listed 27 tests.
- `git diff --check` passed.
