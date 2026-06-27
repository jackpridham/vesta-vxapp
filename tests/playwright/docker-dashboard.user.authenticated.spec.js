const { test, expect } = require('@playwright/test');
const { getOptionalEnv, loginAsRole } = require('./helpers/panel-auth');
const { hasLocalVestaRuntime, isLocalPanelTarget, withSeededAlert } = require('./helpers/docker-runtime-fixtures');

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
  const editLink = card.locator('a[href*="/edit/docker/?container="]').first();
  const editHref = (await editLink.getAttribute('href')) || '';

  expect(owner).not.toBe('');
  expect(name).not.toBe('');
  expect(editHref).not.toBe('');

  return { card, owner, name, editHref };
}

test('docker list dashboard renders cards, constrained health vocabulary, and alert acknowledgement updates state', async ({ page }) => {
  test.skip(!hasLocalVestaRuntime(), 'Dashboard alert coverage requires local Vesta runtime access for deterministic alert setup.');
  test.skip(!isLocalPanelTarget(), 'Dashboard alert coverage requires PLAYWRIGHT_BASE_URL to target the same host as the local Vesta runtime.');
  await loginAsRole(page, 'dockerUser');
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { owner, name } = await requireRealDockerList(page, preferredContainer);
  const seededAlert = withSeededAlert(owner, name);

  try {
    await page.goto('/list/docker/');

    await expect(page.locator('#docker-health-dashboard')).toBeVisible();
    await expect(page.locator('#docker-alerts-panel')).toBeVisible();

    const badgeLocator = page.locator('.docker-card-health-badge');
    const badgeCount = await badgeLocator.count();
    expect(badgeCount).toBeGreaterThan(0);
    const badges = await badgeLocator.allTextContents();
    expect(badges.every((badge) => allowedHealthStates.has(badge.trim().toLowerCase()))).toBeTruthy();

    await waitForMetricValue(page, '#docker-card-cpu', 'No data', /\d/);
    await waitForMetricValue(page, '#docker-card-mem', 'No data', /\d/);
    await waitForMetricValue(page, '#docker-card-rx', 'No data', /\d/);
    await waitForMetricValue(page, '#docker-card-tx', 'No data', /\d/);
    await expect(page.locator('#docker-card-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
    await waitForMetricValue(page, '#docker-card-health-updated', 'No data', /\d/);
    await expect(page.locator('#docker-card-alert-count')).toHaveText(/^\d+$/);

    const targetAlert = page.locator('#docker-alerts-panel article').filter({
      hasText: new RegExp(escapeRegExp(seededAlert.seededTitle), 'i'),
    }).filter({
      hasText: new RegExp(`Container:\\s*${escapeRegExp(name)}\\s*/\\s*Owner:\\s*${escapeRegExp(owner)}`, 'i'),
    });
    await expect(targetAlert).toHaveCount(1);

    const acknowledgeButton = targetAlert.locator('#docker-alert-acknowledge');
    await expect(acknowledgeButton).toBeVisible();
    await acknowledgeButton.click();
    await expect(targetAlert).toContainText(/Ack:\s*yes/i);
  } finally {
    seededAlert.restore();
  }
});

test('docker edit page renders live metrics and chart containers after stats data returns', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { editHref } = await requireRealDockerList(page, preferredContainer);
  await page.goto(editHref);

  await expect(page.locator('#docker-live-metrics')).toBeVisible();
  await waitForRenderedSeries(page, '#docker-chart-cpu');
  await waitForRenderedSeries(page, '#docker-chart-mem');
  await waitForRenderedSeries(page, '#docker-chart-rx');
  await waitForRenderedSeries(page, '#docker-chart-tx');
  await waitForMetricValue(page, '#docker-detail-status', 'No data', /^(running|restarting|created|exited|paused|dead|unknown)$/i);
  await expect(page.locator('#docker-detail-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
  await waitForMetricValue(page, '#docker-detail-health-updated', 'No data', /\d/);
});
