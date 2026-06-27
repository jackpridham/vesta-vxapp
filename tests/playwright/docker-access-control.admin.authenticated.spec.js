const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');

test('admin server navigation still exposes the docker page', async ({ page }) => {
  await page.goto('/list/server/');

  const dockerLink = page.locator('a[href="/list/docker/"]').filter({ hasText: /docker/i }).first();
  await expect(dockerLink).toBeVisible();
});

test('admin docker list shows owner-aware rows and can pivot by owner when multiple owners exist', async ({ page }) => {
  await page.goto('/list/docker/');

  const listVisible = await page.locator('#docker-list-state').isVisible().catch(() => false);
  if (!listVisible) {
    const fallback = page.locator('#docker-unavailable-state, #docker-empty-state, #docker-quota-reached-state').first();
    await expect(fallback).toBeVisible();
    test.skip(true, 'Admin owner-aware row coverage requires a populated Docker list state.');
  }

  await expect(page.locator('#docker-owner-filter')).toContainText(/Owner scope/i);

  const firstCard = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  await expect(firstCard).toBeVisible();
  await expect(firstCard).toHaveAttribute('data-owner', /.+/);
  await expect(firstCard).toContainText(/Owner/i);

  const ownerSelect = page.locator('form[action="/list/docker/"] select[name="user"]');
  const optionValues = await ownerSelect.locator('option').evaluateAll((options) =>
    options.map((option) => option.value).filter((value) => value)
  );

  if (optionValues.length < 2) {
    test.skip(true, 'Owner pivot coverage requires multiple managed-container owners.');
  }

  const preferredOwner = getOptionalEnv('PLAYWRIGHT_DOCKER_USER');
  const pivotOwner = optionValues.includes(preferredOwner) ? preferredOwner : optionValues[0];

  await ownerSelect.selectOption(pivotOwner);
  await page.waitForLoadState('networkidle');
  await expect(page).toHaveURL(new RegExp(`/list/docker/\\?user=${encodeURIComponent(pivotOwner)}`));

  const filteredCards = page.locator('#docker-list-cards article[id^="docker-card-"]');
  await expect(filteredCards.first()).toBeVisible();
  const owners = await filteredCards.evaluateAll((cards) => cards.map((card) => card.getAttribute('data-owner') || ''));
  expect(owners.every((owner) => owner === pivotOwner)).toBeTruthy();
});
