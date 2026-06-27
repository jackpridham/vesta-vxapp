# Playwright UI Harness

This repo uses a repo-local Playwright harness for validating Vesta web-panel changes against a live panel endpoint.

## Prerequisites

- Node.js and `npm`
- Chromium browser binary installed via `npm run playwright:install`
- If Linux shared-library dependencies are missing, run `npx playwright install-deps chromium`

## Environment

Copy `.env.playwright.example` to `.env.playwright` or point Playwright at a different file:

```bash
cp .env.playwright.example .env.playwright
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --list
```

Supported variables:

- `PLAYWRIGHT_BASE_URL`: full panel URL, including scheme and port
- `PLAYWRIGHT_LOGIN_SECRET`: optional secret-login gate token from `web/inc/login_url.php`
- `PLAYWRIGHT_ADMIN_USER` / `PLAYWRIGHT_ADMIN_PASSWORD`: enables admin-authenticated project
- `PLAYWRIGHT_DOCKER_USER` / `PLAYWRIGHT_DOCKER_PASSWORD`: enables real non-admin-authenticated project

## Authentication Model

- Anonymous tests always run.
- Authenticated projects are enabled only when the matching credentials are present.
- The setup project performs a real browser login and writes session storage state under `playwright/.auth/`.
- Secret-login installs are handled by visiting `/?<secret>` before `/login/`.

## Useful Commands

```bash
npm run playwright:test -- --list
npm run playwright:test -- --project=chromium-anonymous
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --project=chromium-docker-user-authenticated
PLAYWRIGHT_ENV_FILE=.env.playwright.local PLAYWRIGHT_ADMIN_PASSWORD='...' npm run playwright:test -- --project=chromium-admin-authenticated
```
