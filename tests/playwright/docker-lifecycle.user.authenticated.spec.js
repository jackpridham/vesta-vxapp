const { test, expect } = require('@playwright/test');

async function firstCard(page) {
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
  await page.goto('/list/docker/');

  if (await page.locator('#docker-unavailable-state').isVisible().catch(() => false)) {
    test.skip(true, 'Docker engine is unavailable for lifecycle coverage.');
  }

  const card = await firstCard(page);
  if (!(await card.count())) {
    test.skip(true, 'Lifecycle coverage requires at least one owned Docker container.');
  }

  await expect(card).toBeVisible();
  await expect(page.getByText(/Install Docker/i)).toHaveCount(0);
  await expect(page.locator('#docker-owner-filter')).not.toContainText(/Owner scope/i);

  const initialStatus = await cardStatus(card);

  if (initialStatus === 'running') {
    await clickAction(page, card, '^stop');
    await expect(card.locator('.docker-card-status')).toHaveText(/exited/i);
    await expect(card.getByRole('link', { name: /^start/i })).toBeVisible();

    await clickAction(page, card, '^start');
    await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
    await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();
  } else {
    await clickAction(page, card, '^start');
    await expect(card.locator('.docker-card-status')).toHaveText(/running|created/i);
    await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();

    await clickAction(page, card, '^stop');
    await expect(card.locator('.docker-card-status')).toHaveText(/exited/i);
    await expect(card.getByRole('link', { name: /^start/i })).toBeVisible();

    await clickAction(page, card, '^restart');
    await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
    await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();
    return;
  }

  await clickAction(page, card, '^restart');
  await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
  await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();
});
