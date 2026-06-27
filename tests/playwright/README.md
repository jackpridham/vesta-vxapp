# Playwright UI Harness

This repo uses a repo-local Playwright harness for validating Vesta web-panel changes against a live panel endpoint.

## Prerequisites

- Node.js 18+ and `npm`
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
- `PLAYWRIGHT_DOCKER_EMPTY_USER` / `PLAYWRIGHT_DOCKER_EMPTY_PASSWORD`: optional seeded user that should render `/list/docker/` in the empty state
- `PLAYWRIGHT_DOCKER_QUOTA_USER` / `PLAYWRIGHT_DOCKER_QUOTA_PASSWORD`: optional seeded user that should render `/list/docker/` in the quota-reached state
- `PLAYWRIGHT_DOCKER_OWNER_FILTER_USER`: optional preferred owner value for admin owner-filter coverage when multiple seeded owners exist
- `PLAYWRIGHT_DOCKER_LIFECYCLE_CONTAINER`: optional seeded container name for real start/stop/restart coverage
- `PLAYWRIGHT_DOCKER_TEST_IMAGE`: optional image override for the create-form regression; defaults to `busybox:latest`
- `PLAYWRIGHT_DOCKER_MODAL_CONTAINER`: optional seeded visible container name for real logs/inspect modal coverage
- `PLAYWRIGHT_DOCKER_REMOVE_CONTAINER`: optional disposable seeded container name for real remove-confirm coverage; reseed it between runs because the test confirms deletion
- `PLAYWRIGHT_DOCKER_ALERT_CONTAINER`: optional disposable seeded visible container name with an open alert for real dashboard acknowledge coverage; reseed the alert between runs because the test acknowledges it
- `PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER`: optional seeded visible container name for real dashboard/edit metrics coverage

## Authentication Model

- Anonymous tests always run.
- Authenticated projects are enabled only when the matching credentials are present.
- The setup project performs a real browser login and writes session storage state under `playwright/.auth/`.
- Secret-login installs are handled by visiting `/?<secret>` before `/login/`.

## Project Matrix

- `setup`: creates authenticated storage states for every configured panel role in one run.
- `chromium-anonymous`: always enabled; covers anonymous panel smoke checks without stored auth state.
- `chromium-admin-authenticated`: enabled only when `PLAYWRIGHT_ADMIN_USER` and `PLAYWRIGHT_ADMIN_PASSWORD` are present; loads `playwright/.auth/admin.json`.
- `chromium-docker-user-authenticated`: enabled only when `PLAYWRIGHT_DOCKER_USER` and `PLAYWRIGHT_DOCKER_PASSWORD` are present; loads `playwright/.auth/docker-user.json`.

## Useful Commands

```bash
npm run playwright:test -- --list
npm run playwright:test -- --project=chromium-anonymous
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --project=chromium-docker-user-authenticated
PLAYWRIGHT_ENV_FILE=.env.playwright.local PLAYWRIGHT_ADMIN_PASSWORD='...' npm run playwright:test -- --project=chromium-admin-authenticated
```
