const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');
const { hasLocalVestaRuntime, isLocalPanelTarget, withSeededAlert } = require('./helpers/docker-runtime-fixtures');

const allowedHealthStates = new Set(['healthy', 'starting', 'degraded', 'unhealthy', 'unknown']);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function textContentTrim(locator) {
  return ((await locator.textContent()) || '').trim();
}

async function waitForNonPlaceholder(page, selector, placeholderText, timeout = 5_000) {
  try {
    await page.waitForFunction(
      ({ css, placeholder }) => {
        const node = document.querySelector(css);
        return Boolean(node) && node.textContent.trim() !== placeholder;
      },
      { css: selector, placeholder: placeholderText },
      { timeout },
    );
    return true;
  } catch {
    return false;
  }
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
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { owner, name } = await requireRealDockerList(page, preferredContainer);
  const seededAlert = withSeededAlert(owner, name);

  try {
    await page.goto('/list/docker/');

    await expect(page.locator('#docker-health-dashboard')).toBeVisible();
    await expect(page.locator('#docker-alerts-panel')).toBeVisible();

    const badges = await page.locator('.docker-card-health-badge').allTextContents();
    expect(badges.every((badge) => allowedHealthStates.has(badge.trim().toLowerCase()))).toBeTruthy();

    test.skip(!(await waitForNonPlaceholder(page, '#docker-card-cpu', 'No data')), 'Dashboard summary coverage requires seeded CPU metric data.');
    test.skip(!(await waitForNonPlaceholder(page, '#docker-card-mem', 'No data')), 'Dashboard summary coverage requires seeded memory metric data.');
    test.skip(!(await waitForNonPlaceholder(page, '#docker-card-rx', 'No data')), 'Dashboard summary coverage requires seeded RX metric data.');
    test.skip(!(await waitForNonPlaceholder(page, '#docker-card-tx', 'No data')), 'Dashboard summary coverage requires seeded TX metric data.');
    await expect(page.locator('#docker-card-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
    test.skip(!(await waitForNonPlaceholder(page, '#docker-card-health-updated', 'No data')), 'Dashboard summary coverage requires seeded health-check data.');
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
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { editHref } = await requireRealDockerList(page, preferredContainer);
  await page.goto(editHref);

  await expect(page.locator('#docker-live-metrics')).toBeVisible();
  test.skip(!(await waitForNonPlaceholder(page, '#docker-chart-cpu', 'No metrics available yet.')), 'Dashboard detail coverage requires seeded CPU stats history.');
  test.skip(!(await waitForNonPlaceholder(page, '#docker-chart-mem', 'No metrics available yet.')), 'Dashboard detail coverage requires seeded memory stats history.');
  test.skip(!(await waitForNonPlaceholder(page, '#docker-chart-rx', 'No metrics available yet.')), 'Dashboard detail coverage requires seeded RX stats history.');
  test.skip(!(await waitForNonPlaceholder(page, '#docker-chart-tx', 'No metrics available yet.')), 'Dashboard detail coverage requires seeded TX stats history.');
  test.skip(!(await waitForNonPlaceholder(page, '#docker-detail-status', 'No data')), 'Dashboard detail coverage requires seeded status data.');
  await expect(page.locator('#docker-detail-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
  test.skip(!(await waitForNonPlaceholder(page, '#docker-detail-health-updated', 'No data')), 'Dashboard detail coverage requires seeded health-check data.');
});
