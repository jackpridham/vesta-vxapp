const { test, expect } = require('@playwright/test');

function targetCard(page, containerName = '') {
  if (containerName) {
    return page.locator(`#docker-list-cards article[data-name="${containerName}"]`).first();
  }

  return page.locator('#docker-list-cards article[id^="docker-card-"]').first();
}

async function cardStatus(card) {
  return ((await card.locator('.docker-card-status').textContent()) || '').trim().toLowerCase();
}

async function clickAction(page, card, label) {
  const link = card.getByRole('link', { name: new RegExp(label, 'i') }).first();
  await link.click();
  await page.waitForLoadState('networkidle');
}

test('start stop restart flows update row state and action labels without admin-only engine controls', async ({ page }) => {
  const preferredContainer = process.env.PLAYWRIGHT_DOCKER_LIFECYCLE_CONTAINER || '';

  await page.goto('/list/docker/');
  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Docker engine is unavailable for lifecycle coverage.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Lifecycle coverage requires a seeded Docker container.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Lifecycle coverage requires at least one visible Docker container.');

  const card = targetCard(page, preferredContainer);
  test.skip((await card.count()) === 0, preferredContainer
    ? `Lifecycle coverage requires seeded container "${preferredContainer}".`
    : 'Lifecycle coverage requires at least one visible Docker container.');
  await expect(card).toBeVisible();
  const targetContainerName = preferredContainer || (await card.getAttribute('data-name')) || '';
  test.skip(!targetContainerName, 'Lifecycle coverage requires a card with a stable data-name attribute.');
  await expect(page.getByText(/Install Docker/i)).toHaveCount(0);
  await expect(page.locator('#docker-owner-filter')).not.toContainText(/Owner scope/i);

  const initialStatus = await cardStatus(card);
  test.skip(!['running', 'exited'].includes(initialStatus), `Lifecycle coverage requires a seeded container in running or exited state, got "${initialStatus || 'unknown'}".`);
  try {
    if (initialStatus !== 'running') {
      await clickAction(page, card, '^start');
      await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/running/i);
      await expect(targetCard(page, targetContainerName).getByRole('link', { name: /^stop/i })).toBeVisible();
    }

    await clickAction(page, card, '^stop');
    await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/exited/i);
    await expect(targetCard(page, targetContainerName).getByRole('link', { name: /^start/i })).toBeVisible();

    await clickAction(page, card, '^start');
    await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/running/i);
    await expect(targetCard(page, targetContainerName).getByRole('link', { name: /^stop/i })).toBeVisible();

    await clickAction(page, card, '^restart');
    await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/running/i);
    await expect(targetCard(page, targetContainerName).getByRole('link', { name: /^stop/i })).toBeVisible();
  } finally {
    const restoredCard = targetCard(page, targetContainerName);
    const finalStatus = await cardStatus(restoredCard);

    if (initialStatus === 'running' && finalStatus !== 'running') {
      await clickAction(page, restoredCard, '^start');
      await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/running/i);
    }

    if (initialStatus !== 'running' && finalStatus === 'running') {
      await clickAction(page, restoredCard, '^stop');
      await expect(targetCard(page, targetContainerName).locator('.docker-card-status')).toHaveText(/exited/i);
    }
  }
});
