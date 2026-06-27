const { test, expect } = require('@playwright/test');
const { loginAsRole } = require('./helpers/panel-auth');

async function visiblePrimaryState(page) {
  // Quota has dedicated coverage in docker-empty-state; this smoke test tracks the
  // narrower list-page contract called out in Task 12.
  const selectors = ['#docker-unavailable-state', '#docker-empty-state', '#docker-list-state'];

  for (const selector of selectors) {
    if (await page.locator(selector).isVisible().catch(() => false)) {
      return selector;
    }
  }

  return '';
}

test('user docker tile links to the docker list and the list renders a contracted state', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  await page.goto('/');

  const dockerTile = page.locator('a[href="/list/docker/"]').filter({ hasText: /DOCKER/i }).first();
  await expect(dockerTile).toBeVisible();

  await dockerTile.click();
  await expect(page).toHaveURL(/\/list\/docker\/?$/);

  const selector = await visiblePrimaryState(page);
  expect(selector).not.toBe('');
  await expect(page.locator(selector)).toBeVisible();
});
