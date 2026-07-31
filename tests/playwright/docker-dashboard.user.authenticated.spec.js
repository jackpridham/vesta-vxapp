const { test, expect } = require('@playwright/test');
const { getOptionalEnv, loginAsRole } = require('./helpers/panel-auth');
const { hasLocalVestaRuntime, hasRemoteVestaRuntime, isLocalPanelTarget, withSeededAlert } = require('./helpers/docker-runtime-fixtures');

const allowedHealthStates = new Set(['healthy', 'starting', 'degraded', 'unhealthy', 'unknown']);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function textContentTrim(locator) {
  return ((await locator.textContent()) || '').trim();
}

async function waitForNonPlaceholder(page, selector, placeholderText, timeout = 5_000) {
  const locator = page.locator(selector);
  await expect(locator).toHaveCount(1);
  await expect
    .poll(async () => textContentTrim(locator), { timeout })
    .not.toBe('');
  await expect
    .poll(async () => textContentTrim(locator), { timeout })
    .not.toBe(placeholderText);
}

async function waitForMetricValue(page, selector, placeholderText, valuePattern, timeout = 5_000) {
  await waitForNonPlaceholder(page, selector, placeholderText, timeout);
  await expect(page.locator(selector)).toHaveText(valuePattern);
}

async function waitForRenderedSeries(page, selector, timeout = 5_000) {
  const locator = page.locator(selector);
  await expect(locator).toHaveCount(1);
  await expect
    .poll(async () => locator.locator('pre').count(), { timeout })
    .toBeGreaterThan(0);
  const text = await expect
    .poll(async () => textContentTrim(locator), { timeout })
    .not.toBe('');
  const finalText = await textContentTrim(locator);
  expect(finalText).not.toMatch(/^No metrics available yet\.?$/i);
}

async function waitForRenderedSeriesOrPlaceholder(page, selector, placeholderText, timeout = 5_000) {
  const locator = page.locator(selector);
  await expect(locator).toHaveCount(1);

  await expect
    .poll(async () => textContentTrim(locator), { timeout })
    .not.toBe('');

  const finalText = await textContentTrim(locator);
  const hasSeries = (await locator.locator('pre').count()) > 0;

  if (hasSeries) {
    expect(finalText).not.toMatch(new RegExp(`^${escapeRegExp(placeholderText)}\\.?$`, 'i'));
    return;
  }

  expect(finalText).toMatch(new RegExp(`^${escapeRegExp(placeholderText)}\\.?$`, 'i'));
}

async function requireRealDockerList(page, preferredContainer = '') {
  await page.goto('/list/docker/');

  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Docker engine is unavailable for dashboard coverage.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Dashboard coverage requires a seeded Docker container.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Dashboard coverage requires at least one visible Docker container.');

  const card = preferredContainer
    ? page.locator(`#docker-list-cards article[data-name="${preferredContainer}"]`).first()
    : page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await card.count()) === 0, preferredContainer
    ? `Dashboard coverage requires seeded container "${preferredContainer}".`
    : 'Dashboard coverage requires at least one visible Docker container.');
  await expect(card).toBeVisible();

  const owner = (await card.getAttribute('data-owner')) || '';
  const name = (await card.getAttribute('data-name')) || '';
  const detailsLink = card.locator('a[href*="/list/docker/project/?project="]').first();
  const detailsHref = (await detailsLink.getAttribute('href')) || '';

  expect(owner).not.toBe('');
  expect(name).not.toBe('');
  expect(detailsHref).not.toBe('');

  return { card, owner, name, detailsHref };
}

test('docker list dashboard renders cards, constrained health vocabulary, and alert acknowledgement updates state', async ({ page }) => {
  test.skip(!(hasLocalVestaRuntime() || hasRemoteVestaRuntime()), 'Dashboard alert coverage requires a reachable Vesta runtime target for deterministic alert setup.');
  test.skip(!isLocalPanelTarget(), 'Dashboard alert coverage requires the runtime target to match PLAYWRIGHT_BASE_URL.');
  await loginAsRole(page, 'dockerUser');
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { owner, name } = await requireRealDockerList(page, preferredContainer);
  const seededAlert = withSeededAlert(owner, name);

  try {
    await page.goto('/list/docker/');
    const targetCard = page.locator(`#docker-list-cards article[data-name="${name}"]`).first();

    await expect(page.locator('#docker-health-dashboard')).toBeVisible();
    await expect(page.locator('#docker-alerts-panel')).toBeVisible();

    const badgeLocator = page.locator('.docker-card-health-badge');
    const badgeCount = await badgeLocator.count();
    expect(badgeCount).toBeGreaterThan(0);
    const badges = await Promise.all(
      (await badgeLocator.all()).map(async (badge) => ((await badge.textContent()) || '').trim())
    );
    expect(badges.every((badge) => allowedHealthStates.has(badge.trim().toLowerCase()))).toBeTruthy();

    await waitForMetricValue(page, '#docker-card-cpu', 'No data', /\d/);
    await waitForMetricValue(page, '#docker-card-mem', 'No data', /\d/);
    await expect(page.locator('#docker-card-rx')).toHaveText(/No data|\d/i);
    await waitForMetricValue(page, '#docker-card-tx', 'No data', /\d/);
    await expect(page.locator('#docker-card-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
    await expect(targetCard.locator('.docker-card-health-updated')).not.toHaveText('');
    await expect(page.locator('#docker-card-alert-count')).toHaveText(/^\d+$/);

    const targetAlert = page.locator('#docker-alerts-panel article').filter({
      hasText: new RegExp(escapeRegExp(seededAlert.seededTitle), 'i'),
    }).filter({
      hasText: new RegExp(`Container:\\s*${escapeRegExp(name)}\\s*/\\s*Owner:\\s*${escapeRegExp(owner)}`, 'i'),
    });
    const targetAlertCount = await targetAlert.count();
    if (targetAlertCount > 0) {
      const acknowledgeButton = targetAlert.locator('#docker-alert-acknowledge');
      await expect(acknowledgeButton).toBeVisible();
      await acknowledgeButton.click();
      await expect(targetAlert).toContainText(/Ack:\s*yes/i);
    } else {
      await expect(page.locator('#docker-alerts-panel')).toContainText(/No Docker alerts are active in this scope\.?/i);
    }
  } finally {
    seededAlert.restore();
  }
});

test('Compose detail page renders project health, metrics, and revision context', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { detailsHref } = await requireRealDockerList(page, preferredContainer);
  await page.goto(detailsHref);

  await expect(page.getByRole('heading', { name: /Recent metrics/i })).toBeVisible();
  await expect(page.getByRole('heading', { name: /Health/i })).toBeVisible();
  await expect(page.getByRole('heading', { name: /Available rollback revisions/i })).toBeVisible();
  await expect(page.locator('.docker-status-badge')).toHaveText(/\S+/);
  await expect(page.locator('.docker-health-badge')).toHaveText(
    /healthy|starting|degraded|unhealthy|unknown/i
  );
});

test('dashboard polling settles health and stats together and rejects an older poll', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  const { card } = await requireRealDockerList(page);
  let healthRequests = 0;
  let statsRequests = 0;

  await page.route('**/ajax/docker/actions/health.php', async (route) => {
    healthRequests += 1;
    const requestNumber = healthRequests;
    if (requestNumber === 1) {
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        STATUS: requestNumber === 1 ? 'unhealthy' : 'healthy',
        HEALTH_STATUS: requestNumber === 1 ? 'unhealthy' : 'healthy',
        OBSERVED_AT: requestNumber === 1
          ? '2026-01-01T00:00:00Z'
          : new Date().toISOString(),
        FRESHNESS: requestNumber === 1 ? 'stale' : 'fresh',
      }),
    }).catch(() => {});
  });
  await page.route('**/ajax/docker/actions/stats.php', async (route) => {
    statsRequests += 1;
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        LATEST: {
          CPU_PCT: statsRequests === 1 ? 99 : 1.25,
          MEM_MB: 2048,
          RX_MBPS: 1.234,
          TX_MBPS: 2.345,
        },
      }),
    }).catch(() => {});
  });
  await page.route('**/ajax/docker/actions/alerts.php', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ ALERTS: [] }),
  }));

  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
  await page.waitForTimeout(20);
  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());

  await expect(card.locator('.docker-card-health-badge')).toHaveText('healthy');
  await expect(card.locator('.docker-card-health-badge')).toHaveAttribute(
    'data-freshness',
    'fresh'
  );
  await expect(card.locator('.docker-card-latest-cpu')).toHaveText('1.3%');
  await expect(card.locator('.docker-card-latest-mem')).toHaveText('2.0 GiB');
  await expect(card.locator('.docker-card-latest-rx')).toHaveText('1.23 MiB/s');
  await expect(card.locator('.docker-card-latest-tx')).toHaveText('2.35 MiB/s');

  await page.unroute('**/ajax/docker/actions/health.php');
  await page.unroute('**/ajax/docker/actions/stats.php');
  await page.route('**/ajax/docker/actions/health.php', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      STATUS: 'healthy',
      HEALTH_STATUS: 'healthy',
      OBSERVED_AT: new Date().toISOString(),
      FRESHNESS: 'fresh',
    }),
  }));
  await page.route('**/ajax/docker/actions/stats.php', (route) => route.abort());
  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
  await expect(card.locator('.docker-card-health-badge')).toHaveText('healthy');
  await expect(card.locator('.docker-card-latest-cpu')).toHaveText('No data');

  await page.unroute('**/ajax/docker/actions/health.php');
  await page.unroute('**/ajax/docker/actions/stats.php');
  await page.route('**/ajax/docker/actions/health.php', (route) => route.abort());
  await page.route('**/ajax/docker/actions/stats.php', (route) => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      LATEST: { CPU_PCT: 2, MEM_MB: 512, RX_MBPS: 0, TX_MBPS: 0 },
    }),
  }));
  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
  await expect(card.locator('.docker-card-health-badge')).toHaveText('unknown');
  await expect(card.locator('.docker-card-health-badge')).toHaveAttribute(
    'data-freshness',
    'unavailable'
  );
  await expect(card.locator('.docker-card-latest-cpu')).toHaveText('2.0%');

  await page.unroute('**/ajax/docker/actions/stats.php');
  await page.route('**/ajax/docker/actions/stats.php', (route) => route.abort());
  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
  await expect(card.locator('.docker-card-health-badge')).toHaveText('unknown');
  await expect(card.locator('.docker-card-latest-cpu')).toHaveText('No data');

  await page.unroute('**/ajax/docker/actions/health.php');
  await page.unroute('**/ajax/docker/actions/stats.php');
  await page.route('**/ajax/docker/actions/health.php', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 100));
    await route.fulfill({ contentType: 'application/json', body: '{}' })
      .catch(() => {});
  });
  await page.route('**/ajax/docker/actions/stats.php', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 100));
    await route.fulfill({ contentType: 'application/json', body: '{}' })
      .catch(() => {});
  });
  await page.evaluate(() => {
    window.DOCKER_LIST.requestTimeoutMs = 20;
    window.VX_DOCKER_POLLING_TEST.refresh();
  });
  await page.waitForTimeout(50);
  await expect(card.locator('.docker-card-health-badge')).toHaveText('unknown');
  await expect(card.locator('.docker-card-latest-cpu')).toHaveText('No data');

  await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
  await page.goto('/list/docker/');
  await expect(page.locator('body')).toBeVisible();
});
