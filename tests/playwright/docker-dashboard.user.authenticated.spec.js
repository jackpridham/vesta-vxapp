const { test, expect } = require('@playwright/test');

const allowedHealthStates = new Set(['healthy', 'starting', 'degraded', 'unhealthy', 'unknown']);

function mockMetric(owner, name) {
  return {
    OWNER: owner,
    NAME: name,
    PERIOD: '5m',
    CPU_PCT: [{ TS: '2026-06-27T14:00:00Z', VALUE: 12.4 }],
    MEM_MB: [{ TS: '2026-06-27T14:00:00Z', VALUE: 384 }],
    RX_MBPS: [{ TS: '2026-06-27T14:00:00Z', VALUE: 1.2 }],
    TX_MBPS: [{ TS: '2026-06-27T14:00:00Z', VALUE: 0.6 }],
    LATEST: {
      CPU_PCT: 12.4,
      MEM_MB: 384,
      RX_MBPS: 1.2,
      TX_MBPS: 0.6,
    },
  };
}

async function ensureDashboardListFixture(page) {
  await page.evaluate(() => {
    const hide = ['#docker-unavailable-state', '#docker-empty-state', '#docker-quota-reached-state'];
    const show = ['#docker-list-state', '#docker-health-dashboard', '#docker-alerts-panel'];

    hide.forEach((selector) => {
      const node = document.querySelector(selector);
      if (node) {
        node.style.display = 'none';
      }
    });

    show.forEach((selector) => {
      const node = document.querySelector(selector);
      if (node) {
        node.style.display = '';
      }
    });

    const cards = document.querySelector('#docker-list-cards');
    if (!cards) {
      return;
    }

    if (!cards.querySelector('[data-playwright-dashboard="yes"]')) {
      const article = document.createElement('article');
      article.id = 'docker-card-dockeruser-panel-app';
      article.className = 'l-unit';
      article.dataset.owner = 'dockeruser';
      article.dataset.name = 'panel-app';
      article.dataset.playwrightDashboard = 'yes';
      article.innerHTML = `
        <div class="actions-panel clearfix">
          <div class="actions-panel__col actions-panel__edit"><a href="/edit/docker/?container=panel-app">edit</a></div>
        </div>
        <div class="l-unit__stats">
          <b class="docker-card-status">running</b>
          <b class="docker-card-health-badge">healthy</b>
          <b class="docker-card-health-updated">2026-06-27 14:03:00</b>
          <b class="docker-card-alert-count">0</b>
          <b class="docker-card-latest-cpu">No data</b>
          <b class="docker-card-latest-mem">No data</b>
          <span class="docker-card-latest-rx">No data</span>
          <span class="docker-card-latest-tx">No data</span>
        </div>
      `;
      cards.prepend(article);
    }

    window.DOCKER_LIST = window.DOCKER_LIST || {};
    window.DOCKER_LIST.token = window.DOCKER_LIST.token || 'test-token';
    window.DOCKER_LIST.dockerAvailable = true;
    window.DOCKER_LIST.primaryState = 'list';
    window.DOCKER_LIST.ownerScope = window.DOCKER_LIST.ownerScope || 'dockeruser';
    window.DOCKER_LIST.containers = [
      {
        owner: 'dockeruser',
        name: 'panel-app',
        healthStatus: 'healthy',
        lastHealthAt: '2026-06-27 14:03:00',
      },
    ];
  });
}

async function buildEditFixture(page) {
  await page.setContent(`
    <html>
      <body>
        <section id="docker-live-metrics">
          <div id="docker-chart-cpu">No metrics available yet.</div>
          <div id="docker-chart-mem">No metrics available yet.</div>
          <div id="docker-chart-rx">No metrics available yet.</div>
          <div id="docker-chart-tx">No metrics available yet.</div>
          <div id="docker-detail-status">No data</div>
          <div id="docker-detail-health-status">No data</div>
          <div id="docker-detail-health-updated">No data</div>
        </section>
        <section id="docker-alerts-panel">
          <div class="docker-alerts-list"></div>
          <button id="docker-alert-acknowledge" style="display:none;">Acknowledge alert</button>
        </section>
        <script>
          window.DOCKER_EDIT = {
            token: 'test-token',
            owner: 'dockeruser',
            name: 'panel-app',
            statsUrl: '/ajax/docker/actions/stats.php',
            healthUrl: '/ajax/docker/actions/health.php',
            alertsUrl: '/ajax/docker/actions/alerts.php',
            acknowledgeUrl: '/ajax/docker/actions/acknowledge_alert.php',
            pollIntervalMs: 30000
          };
        </script>
      </body>
    </html>
  `);
  await page.addScriptTag({ path: 'web/js/jquery-1.7.2.min.js' });
  await page.addScriptTag({ path: 'web/js/pages/edit_docker.js' });
}

test('docker list dashboard renders cards, constrained health vocabulary, and alert acknowledgement updates state', async ({ page }) => {
  let acknowledged = false;

  await page.route('**/ajax/docker/actions/stats.php', async (route) => {
    const params = new URLSearchParams(route.request().postData() || '');
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mockMetric(params.get('owner') || '', params.get('name') || '')),
    });
  });

  await page.route('**/ajax/docker/actions/alerts.php', async (route) => {
    const params = new URLSearchParams(route.request().postData() || '');
    const owner = params.get('owner') || '';
    const alertPayload = acknowledged
      ? { OWNER: owner, ALERTS: [] }
      : {
          OWNER: owner,
          ALERTS: [
            {
              AID: '1',
              OWNER: owner,
              NAME: 'panel-app',
              LEVEL: 'warning',
              TYPE: 'health',
              STATUS: 'open',
              ACK: 'no',
              TITLE: 'Health check failing',
              MESSAGE: 'GET /health returned 500 three times',
              STARTED: '2026-06-27 14:01:00',
              LAST_SEEN: '2026-06-27 14:03:00',
            },
          ],
        };

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(alertPayload),
    });
  });

  await page.route('**/ajax/docker/actions/acknowledge_alert.php', async (route) => {
    acknowledged = true;
    const params = new URLSearchParams(route.request().postData() || '');
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ OK: true, OWNER: params.get('owner'), AID: params.get('aid') }),
    });
  });

  await page.goto('/list/docker/');
  await ensureDashboardListFixture(page);

  await expect(page.locator('#docker-health-dashboard')).toBeVisible();
  await expect(page.locator('#docker-alerts-panel')).toBeVisible();

  const badges = await page.locator('.docker-card-health-badge').allTextContents();
  expect(badges.every((badge) => allowedHealthStates.has(badge.trim().toLowerCase()))).toBeTruthy();

  await expect(page.locator('#docker-card-cpu')).toHaveText(/12\.4%/);
  await expect(page.locator('#docker-card-mem')).toHaveText(/384\.0 MB/);
  await expect(page.locator('#docker-card-rx')).toHaveText(/1\.20 MB\/s/);
  await expect(page.locator('#docker-card-tx')).toHaveText(/0\.60 MB\/s/);
  await expect(page.locator('#docker-card-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
  await expect(page.locator('#docker-card-health-updated')).toContainText(/\S+/);
  await expect(page.locator('#docker-card-alert-count')).toHaveText(/1/);

  const acknowledgeButton = page.locator('#docker-alert-acknowledge');
  await expect(acknowledgeButton).toBeVisible();
  await acknowledgeButton.click();

  await expect(page.locator('#docker-alerts-panel')).toContainText(/No Docker alerts are active/i);
  await expect(page.locator('#docker-card-alert-count')).toHaveText(/0/);
});

test('docker edit page renders live metrics and chart containers after stats data returns', async ({ page }) => {
  await page.route('**/ajax/docker/actions/stats.php', async (route) => {
    const params = new URLSearchParams(route.request().postData() || '');
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mockMetric(params.get('owner') || '', params.get('name') || '')),
    });
  });

  await page.route('**/ajax/docker/actions/health.php', async (route) => {
    const params = new URLSearchParams(route.request().postData() || '');
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        OWNER: params.get('owner') || '',
        NAME: params.get('name') || '',
        STATUS: 'running',
        HEALTH_STATUS: 'healthy',
        LAST_HEALTH_AT: '2026-06-27 14:03:00',
      }),
    });
  });

  await page.route('**/ajax/docker/actions/alerts.php', async (route) => {
    const params = new URLSearchParams(route.request().postData() || '');
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ OWNER: params.get('owner') || '', ALERTS: [] }),
    });
  });

  await buildEditFixture(page);

  await expect(page.locator('#docker-live-metrics')).toBeVisible();
  await expect(page.locator('#docker-chart-cpu pre')).toContainText(/2026-06-27T14:00:00Z/);
  await expect(page.locator('#docker-chart-mem pre')).toContainText(/384 MB/);
  await expect(page.locator('#docker-chart-rx pre')).toContainText(/1\.2 MB\/s/);
  await expect(page.locator('#docker-chart-tx pre')).toContainText(/0\.6 MB\/s/);
  await expect(page.locator('#docker-detail-status')).toHaveText(/running/i);
  await expect(page.locator('#docker-detail-health-status')).toHaveText(/healthy/i);
  await expect(page.locator('#docker-detail-health-updated')).toContainText(/2026-06-27 14:03:00/);
});
