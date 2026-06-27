const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');

const allowedHealthStates = new Set(['healthy', 'starting', 'degraded', 'unhealthy', 'unknown']);

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
  const alertContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_ALERT_CONTAINER');
  test.skip(!alertContainer, 'Dashboard alert-acknowledge coverage requires PLAYWRIGHT_DOCKER_ALERT_CONTAINER to target a disposable seeded container with an open alert.');
  await requireRealDockerList(page, alertContainer);

  await expect(page.locator('#docker-health-dashboard')).toBeVisible();
  await expect(page.locator('#docker-alerts-panel')).toBeVisible();

  const badges = await page.locator('.docker-card-health-badge').allTextContents();
  expect(badges.every((badge) => allowedHealthStates.has(badge.trim().toLowerCase()))).toBeTruthy();

  await expect(page.locator('#docker-card-cpu')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-card-mem')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-card-rx')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-card-tx')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-card-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
  await expect(page.locator('#docker-card-health-updated')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-card-alert-count')).toHaveText(/^\d+$/);

  const acknowledgeButton = page.locator('#docker-alert-acknowledge');
  test.skip((await acknowledgeButton.isVisible().catch(() => false)) === false, 'Dashboard alert-acknowledge coverage requires a seeded open Docker alert.');
  await acknowledgeButton.click();
  await expect(acknowledgeButton).toBeHidden();
  await expect(page.locator('#docker-alerts-panel')).toContainText(/Ack:\s*yes/i);
});

test('docker edit page renders live metrics and chart containers after stats data returns', async ({ page }) => {
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_DASHBOARD_CONTAINER');
  const { editHref } = await requireRealDockerList(page, preferredContainer);
  await page.goto(editHref);

  await expect(page.locator('#docker-live-metrics')).toBeVisible();
  await expect(page.locator('#docker-chart-cpu')).not.toContainText(/No metrics available yet\./i);
  await expect(page.locator('#docker-chart-mem')).not.toContainText(/No metrics available yet\./i);
  await expect(page.locator('#docker-chart-rx')).not.toContainText(/No metrics available yet\./i);
  await expect(page.locator('#docker-chart-tx')).not.toContainText(/No metrics available yet\./i);
  await expect(page.locator('#docker-detail-status')).not.toHaveText(/^No data$/);
  await expect(page.locator('#docker-detail-health-status')).toHaveText(/healthy|starting|degraded|unhealthy|unknown/i);
  await expect(page.locator('#docker-detail-health-updated')).not.toHaveText(/^No data$/);
});
