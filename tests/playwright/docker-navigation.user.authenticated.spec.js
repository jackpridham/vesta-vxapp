const { test, expect } = require('@playwright/test');

async function visiblePrimaryState(page) {
  const selectors = ['#docker-unavailable-state', '#docker-empty-state', '#docker-list-state'];

  for (const selector of selectors) {
    if (await page.locator(selector).isVisible().catch(() => false)) {
      return selector;
    }
  }

  return '';
}

test('user docker tile links to the docker list and the list renders a contracted state', async ({ page }) => {
  await page.goto('/');

  const dockerTile = page.locator('a[href="/list/docker/"]').filter({ hasText: /DOCKER/i }).first();
  await expect(dockerTile).toBeVisible();

  await dockerTile.click();
  await expect(page).toHaveURL(/\/list\/docker\/?$/);

  test.skip(
    await page.locator('#docker-quota-reached-state').isVisible().catch(() => false),
    'Quota-reached coverage is exercised by the dedicated docker-empty-state suite.',
  );

  const selector = await visiblePrimaryState(page);
  expect(selector).not.toBe('');
  await expect(page.locator(selector)).toBeVisible();
});
