## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: yes
- Sensitive categories: runtime credentials, panel passwords

## Section Inventory
1. Task 13: Validate And Close Out Against staging.example.com

## Sanitized Section Summaries
### Task 13: Validate And Close Out Against staging.example.com
- Requires a staging runtime overlay to be applied by internal IP only, without deleting user state.
- Requires pre-E2E runtime validation for deployed marker/version, package hold, Bash/PHP syntax, proxy templates, nginx/Apache config, and Docker engine availability.
- Requires scratch Docker test state plus a live Playwright run covering anonymous, non-admin, and admin Docker panel flows against `https://192.0.2.20:8083`.
- Requires backend validation for persisted route linkage, health, stats, alerts, and nginx routing through the seeded Docker container.
- Requires a standalone closeout report and a matching staging README update, plus cleanup of the scratch objects.

## Technical Claims
- Staging was restamped to deployed runtime commit `02e4042d` and retained `apt-mark hold vesta`.
- Final Playwright validation against `.env.playwright.local` completed with `17 passed` across anonymous, docker-user, and admin-authenticated projects.
- The validation loop exposed and fixed three issues before closeout: admin `login as` owner-scope leakage, missing nginx reload after Docker route sync, and a flaky remove-modal assertion in the Docker user suite.
- Final backend evidence shows `dockere2e/app` route metadata persisted in both `web.conf` and `docker.conf`, health/status JSON is populated, stats JSON includes populated `CPU_PCT`, `MEM_MB`, `RX_MBPS`, `TX_MBPS`, and `LATEST`, and `docker-e2e.local` returns the container body through nginx after the route-sync fix.
- Closeout artifacts now exist in `.docs/validation/staging-docker-e2e-closeout.md` and `<operations-repo>/Servers/hypervisor.example.com/staging.example.com/README.md`.

## Sensitive Content Handling
- The admin password and any session/login tokens are omitted from this snapshot.
- Environment variable names are referenced, but their values are redacted or summarized.
