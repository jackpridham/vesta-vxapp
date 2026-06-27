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

async function requireRealDockerList(page) {
  await page.goto('/list/docker/');

  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Docker engine is unavailable for dashboard coverage.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Dashboard coverage requires a seeded Docker container.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Dashboard coverage requires at least one visible Docker container.');

  const card = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await card.count()) === 0, 'Dashboard coverage requires at least one visible Docker container.');
  await expect(card).toBeVisible();

  const owner = (await card.getAttribute('data-owner')) || '';
  const name = (await card.getAttribute('data-name')) || '';
  const editLink = card.locator('a[href*="/edit/docker/?container="]').first();
  const editHref = (await editLink.getAttribute('href')) || '';

  expect(owner).not.toBe('');
  expect(name).not.toBe('');
  expect(editHref).not.toBe('');

  return { card, owner, name, editHref };
}

test('docker list dashboard renders cards, constrained health vocabulary, and alert acknowledgement updates state', async ({ page }) => {
  let acknowledged = false;
  let selectedContainer = null;

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
              OWNER: selectedContainer ? selectedContainer.owner : owner,
              NAME: selectedContainer ? selectedContainer.name : 'seeded-app',
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

  selectedContainer = await requireRealDockerList(page);

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

  const { editHref } = await requireRealDockerList(page);
  await page.goto(editHref);

  await expect(page.locator('#docker-live-metrics')).toBeVisible();
  await expect(page.locator('#docker-chart-cpu pre')).toContainText(/2026-06-27T14:00:00Z/);
  await expect(page.locator('#docker-chart-mem pre')).toContainText(/384 MB/);
  await expect(page.locator('#docker-chart-rx pre')).toContainText(/1\.2 MB\/s/);
  await expect(page.locator('#docker-chart-tx pre')).toContainText(/0\.6 MB\/s/);
  await expect(page.locator('#docker-detail-status')).toHaveText(/running/i);
  await expect(page.locator('#docker-detail-health-status')).toHaveText(/healthy/i);
  await expect(page.locator('#docker-detail-health-updated')).toContainText(/2026-06-27 14:03:00/);
});
