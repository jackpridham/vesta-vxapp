# staging Docker E2E Closeout

> **Historical validation:** This report proves the legacy direct-container
> MVP only. It is not evidence for Docker Compose orchestration. Current
> implementation guidance is indexed by
> [the operator architecture](../../docs/container-orchestration.md).

Date: `2026-06-27`
Panel URL: `https://192.0.2.20:8083`
Deployed runtime commit: `02e4042d`
Local validation harness HEAD after final rerun: `30fd00d1`
Playwright env file: `.env.playwright.local`

## Scratch Objects

- Package: `docker-e2e`
- User: `dockere2e`
- Domain: `docker-e2e.local`
- Container: `app`
- Empty-state user: `dockempt`
- Quota-state user: `dockqta`

## Commands Run

```bash
# Overlay and runtime stamp
TARGET_HOST="192.0.2.20"
TARGET_SSH="operator@${TARGET_HOST}"
DEPLOY_COMMIT="02e4042d"
DEPLOY_DATE="2026-06-27"

ssh "$TARGET_SSH" 'rm -rf /tmp/vortex-vesta-overlay && mkdir -p /tmp/vortex-vesta-overlay'
rsync -a bin/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/bin/"
rsync -a func/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/func/"
rsync -a web/ "$TARGET_SSH:/tmp/vortex-vesta-overlay/web/"
rsync -a install/debian/13/templates/web/nginx/vx-proxy.tpl "$TARGET_SSH:/tmp/vortex-vesta-overlay/vx-proxy.tpl"
rsync -a install/debian/13/templates/web/nginx/vx-proxy.stpl "$TARGET_SSH:/tmp/vortex-vesta-overlay/vx-proxy.stpl"
ssh "$TARGET_SSH" "sudo DEPLOY_COMMIT='$DEPLOY_COMMIT' DEPLOY_DATE='$DEPLOY_DATE' bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home
rsync -a /tmp/vortex-vesta-overlay/bin/ /usr/local/vesta/bin/
rsync -a /tmp/vortex-vesta-overlay/func/ /usr/local/vesta/func/
rsync -a /tmp/vortex-vesta-overlay/web/ /usr/local/vesta/web/
install -m 0644 /tmp/vortex-vesta-overlay/vx-proxy.tpl /usr/local/vesta/data/templates/web/nginx/vx-proxy.tpl
install -m 0644 /tmp/vortex-vesta-overlay/vx-proxy.stpl /usr/local/vesta/data/templates/web/nginx/vx-proxy.stpl
echo "$DEPLOY_COMMIT" > /usr/local/vesta/conf/vortex-vesta-fork-commit
echo "0.9.9-0-16+vxapp.${DEPLOY_COMMIT}" > /usr/local/vesta/version.txt
echo "$DEPLOY_DATE" > /usr/local/vesta/build_date.txt
apt-mark hold vesta
systemctl restart vesta nginx apache2
EOF

# Runtime validation
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
export VESTA=/usr/local/vesta
export HOMEDIR=/home
hostname -f
cat /usr/local/vesta/conf/vortex-vesta-fork-commit
cat /usr/local/vesta/version.txt
cat /usr/local/vesta/build_date.txt
apt-mark showhold | grep '^vesta$'
bash -n /usr/local/vesta/func/vx/docker.sh /usr/local/vesta/bin/v-add-docker-container /usr/local/vesta/bin/v-change-docker-container /usr/local/vesta/bin/v-list-docker-containers /usr/local/vesta/bin/v-list-docker-container-stats /usr/local/vesta/bin/v-update-docker-container-health /usr/local/vesta/bin/v-list-docker-container-alerts
php -l /usr/local/vesta/web/list/docker/index.php
php -l /usr/local/vesta/web/add/docker/index.php
php -l /usr/local/vesta/web/edit/docker/index.php
php -l /usr/local/vesta/web/ajax/docker/router.php
php -l /usr/local/vesta/web/ajax/docker/actions/stats.php
php -l /usr/local/vesta/web/ajax/docker/actions/health.php
php -l /usr/local/vesta/web/ajax/docker/actions/alerts.php
nginx -t
apache2ctl configtest
/usr/local/vesta/bin/v-check-docker-engine json || true
EOF

# Scratch state and routed container
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
source /etc/profile.d/vesta.sh
/usr/local/vesta/bin/v-add-user dockere2e ChangeMe-123! dockere2e@local.test docker-e2e Docker E2E
/usr/local/vesta/bin/v-add-web-domain dockere2e docker-e2e.local 192.0.2.20 no none no
/usr/local/vesta/bin/v-add-docker-container dockere2e /tmp/app.spec
/usr/local/vesta/bin/v-start-docker-container dockere2e app || true
/usr/local/vesta/bin/v-update-docker-container-health dockere2e app || true
/usr/local/vesta/bin/v-update-sys-rrd-docker daily || true
EOF

# Playwright
PLAYWRIGHT_ENV_FILE=.env.playwright.local npx playwright test --project=chromium-anonymous --project=chromium-docker-user-authenticated --project=chromium-admin-authenticated

# Backend checks
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
source /etc/profile.d/vesta.sh
/usr/local/vesta/bin/v-list-docker-container dockere2e app json
/usr/local/vesta/bin/v-list-web-domain dockere2e docker-e2e.local json
/usr/local/vesta/bin/v-update-docker-container-health dockere2e app
/usr/local/vesta/bin/v-list-docker-container-health dockere2e app json
/usr/local/vesta/bin/v-update-sys-rrd-docker daily
/usr/local/vesta/bin/v-list-docker-container-stats dockere2e app 5m json
/usr/local/vesta/bin/v-list-docker-container-alerts dockere2e app json || true
grep "DOMAIN='docker-e2e.local'" /usr/local/vesta/data/users/dockere2e/web.conf
grep "NAME='app'" /usr/local/vesta/data/users/dockere2e/docker.conf
curl -H 'Host: docker-e2e.local' http://192.0.2.20/ -I
EOF

# Cleanup
ssh "$TARGET_SSH" "sudo bash -s" <<'EOF'
set -euo pipefail
source /etc/profile.d/vesta.sh
/usr/local/vesta/bin/v-delete-user dockere2e yes || true
/usr/local/vesta/bin/v-delete-user-package docker-e2e || true
EOF
```

## Results

- Overlay validation: `PASS`
  Result: host marker/version/build date were updated, `vesta` remained on hold, Bash syntax checks passed, PHP lint passed for the targeted Docker panel files, `nginx -t` passed, `apache2ctl configtest` passed, Docker engine reported available.
- Playwright anonymous coverage: `PASS`
  Result: login page CSRF/form contract verified.
- Playwright non-admin coverage: `PASS`
  Result: create form, empty/quota states, dashboard, edit metrics, lifecycle, modal flows, delete confirm, navigation, and panel-shell coverage passed in one final run.
- Playwright admin coverage: `PASS`
  Result: admin Docker navigation, owner pivoting, and admin `login as` isolation coverage passed.
- Routing validation: `PASS`
  Result: `web.conf` and `docker.conf` persisted the `docker-e2e.local` <-> `app` route relationship, `PROXY='vx-proxy'`, and the final route response returned the container body `ok` after the route-sync reload fix.
- Metrics validation: `PASS`
  Result: `v-list-docker-container-stats dockere2e app 5m json` returned populated `CPU_PCT`, `MEM_MB`, `RX_MBPS`, `TX_MBPS`, and `LATEST` values in the final backend check.
- Health validation: `PASS`
  Result: `v-list-docker-container-health dockere2e app json` returned `STATUS='running'`, `HEALTH_STATUS='unknown'`, and a populated `LAST_HEALTH_AT`.
- Alerts validation: `PASS`
  Result: live alert acknowledgement coverage passed in Playwright and backend alerts JSON remained valid with an empty `ALERTS` list when no open alerts existed.
- Cleanup validation: `PASS`
  Result: the final cleanup commands were idempotent; by the time they ran, `dockere2e` and `docker-e2e` were already absent and the scripted `|| true` cleanup completed without blocking closeout.

## Artifacts

- HTML Playwright report: `playwright-report/index.html`
- Latest report timestamp: `2026-06-27 23:50:39 +1000`
- Playwright output directory: `test-results/`

## Deviations From The Original Plan

- The initial staging validation run exposed additional runtime gaps that were fixed before closeout:
  - `3204226b`: Docker list owner-scope leakage during admin `login as`
  - `02e4042d`: missing nginx reload in `v-sync-docker-container-route`, plus dashboard metric assertions aligned to legitimate empty-series behavior before RX data appeared
  - `30fd00d1`: remove-modal assertion hardened to tolerate async deletion completion on the live host
- The final deployed runtime commit on the host is `02e4042d`; the final local Playwright harness commit is `30fd00d1`.
