## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 11: Install Playwright For Panel UI Validation

## Sanitized Section Summaries
### Task 11: Install Playwright For Panel UI Validation
- Requires a repo-local Playwright harness for panel UI validation with root-level Node tooling, environment contract, auth setup, smoke specs, and operator docs.
- Requires the project matrix to support anonymous access plus gated admin and docker-user authenticated projects.
- Requires the harness to handle the optional secret-login gate and persist reusable auth state under `playwright/.auth/`.
- Requires validation through non-executing `--list` runs that prove project gating works before Docker-specific UI specs are added.

## Technical Claims
- Root-level Playwright tooling now exists in `package.json`, `package-lock.json`, `playwright.config.js`, and `.env.playwright.example`.
- The auth helper and setup spec now support admin and docker-user credential roles, optional secret-login, and persisted storage state under `playwright/.auth/`.
- Anonymous and authenticated shell smoke specs now target the correct login and user-shell paths for the documented harness contract.
- The README now documents the environment flow, project matrix, secret-login behavior, dependency-install command, and Node 18+ requirement.

## Sensitive Content Handling
- No sensitive literals detected.
