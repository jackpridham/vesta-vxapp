const { test, expect } = require('@playwright/test');

test('admin docker list renders all-users scope safely and groups owners when containers exist', async ({ page }) => {
  await page.goto('/list/docker/');

  await expect(page.locator('.l-header')).toBeVisible();
  await expect(page.locator('#docker-owner-filter')).toContainText(/Owner scope/i);

  const listVisible = await page.locator('#docker-list-state').isVisible().catch(() => false);
  if (!listVisible) {
    await expect(
      page.locator('#docker-unavailable-state, #docker-empty-state, #docker-quota-reached-state').first()
    ).toBeVisible();
    return;
  }

  const cardCount = await page.locator('#docker-list-cards article.l-unit').count();
  if (cardCount === 0) {
    await expect(page.locator('#docker-list-toolbar')).toBeVisible();
    return;
  }

  await expect(page.locator('.docker-owner-group').first()).toBeVisible();
});
