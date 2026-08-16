# Playwright UI Harness

This repo uses a repo-local Playwright harness for validating Vesta web-panel changes against a live panel endpoint.

## Prerequisites

- Node.js 18+ and `npm`
- Chromium browser binary installed via `npm run playwright:install`
- If Linux shared-library dependencies are missing, run `npx playwright install-deps chromium`
- Destructive Docker specs self-seed through the local Vesta runtime, so `/etc/profile.d/vesta.sh` and the Vesta CLI need to be available on the same host that serves the panel
- When the suite relies on those self-seeded Docker fixtures, `PLAYWRIGHT_BASE_URL` must point at that same local host rather than a different remote panel
- Destructive same-host fixtures stay disabled unless `PLAYWRIGHT_LOCAL_RUNTIME_TARGET=yes` is set explicitly; this protects SSH tunnels or local reverse proxies such as `https://127.0.0.1:8083` from mutating the wrong Vesta runtime

## Environment

Install the example as a private local file, then fill in only the values
required for the selected projects:

```bash
install -m 0600 .env.playwright.example .env.playwright.local
PLAYWRIGHT_ENV_FILE=.env.playwright.local npm run playwright:test -- --list
```

The default file is `.env.playwright.local`. An absent default is allowed for
anonymous test discovery. A path selected with `PLAYWRIGHT_ENV_FILE` must
exist. The loader rejects symlinks, non-regular files, files owned by another
user, and any mode other than `0600`.

Supported variables:

- The authenticated UI assertions currently assume the panel is using the English locale strings shipped in `web/inc/i18n/en.php`

- `PLAYWRIGHT_BASE_URL`: full panel URL, including scheme and port
- `PLAYWRIGHT_LOGIN_SECRET`: optional secret-login gate token from `web/inc/login_url.php`
- `PLAYWRIGHT_LOCAL_RUNTIME_TARGET`: set to `yes` only when `PLAYWRIGHT_BASE_URL` truly points at the same machine that provides `/etc/profile.d/vesta.sh`; required for destructive runtime fixture seeding/cleanup
- `PLAYWRIGHT_REMOTE_VESTA_SSH`: optional SSH destination for the exact remote Vesta runtime serving `PLAYWRIGHT_BASE_URL`, for example `operator@<staging-host>`
- `PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP`: optional SSH jump destination for that remote runtime, for example `builder@<staging-jump-host>`; both SSH values must be single destinations without options or whitespace
- `PLAYWRIGHT_PANEL_RUNTIME_HOST`: optional explicit runtime host assertion when `PLAYWRIGHT_BASE_URL` is a loopback SSH tunnel; it must exactly match the host in `PLAYWRIGHT_REMOTE_VESTA_SSH` and must not include a user name
- `PLAYWRIGHT_ADMIN_USER` / `PLAYWRIGHT_ADMIN_PASSWORD`: enables admin-authenticated project
- `PLAYWRIGHT_DOCKER_USER` / `PLAYWRIGHT_DOCKER_PASSWORD`: enables the main real non-admin-authenticated project; seed this user below quota so navigation/create/lifecycle/modal/dashboard coverage lands on the contracted list states instead of the dedicated quota fixture
- `PLAYWRIGHT_DOCKER_EMPTY_USER` / `PLAYWRIGHT_DOCKER_EMPTY_PASSWORD`: optional dedicated user for the empty-state assertions; these supplement but do not replace `PLAYWRIGHT_DOCKER_USER` / `PLAYWRIGHT_DOCKER_PASSWORD`, because the authenticated Docker project is still gated by the main Docker-user credentials
- `PLAYWRIGHT_DOCKER_QUOTA_USER` / `PLAYWRIGHT_DOCKER_QUOTA_PASSWORD`: optional dedicated user for the quota-state assertions; these supplement but do not replace `PLAYWRIGHT_DOCKER_USER` / `PLAYWRIGHT_DOCKER_PASSWORD`, because the authenticated Docker project is still gated by the main Docker-user credentials
- `PLAYWRIGHT_DOCKER_OWNER_FILTER_USER`: optional preferred owner value for admin owner-filter coverage when multiple seeded owners exist
- `PLAYWRIGHT_DOCKER_LIFECYCLE_CONTAINER`: optional seeded container name for real start/stop/restart coverage
- `PLAYWRIGHT_DOCKER_TEST_IMAGE`: optional image override for the create-form regression; defaults to `busybox:1.36.1`
- `PLAYWRIGHT_DOCKER_MODAL_CONTAINER`: optional seeded visible container name for real logs/inspect modal coverage
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

If the current host does not provide `/etc/profile.d/vesta.sh` and the local Vesta runtime, use the shell syntax checks plus `npm run playwright:test -- --list` as the Task 12 fallback validation and defer the full Docker-backed browser runs to the staging closeout host in Task 13. If the runtime is local but you are reaching it through a tunnel or reverse proxy, leave `PLAYWRIGHT_LOCAL_RUNTIME_TARGET` unset so the destructive fixture helpers stay disabled.
