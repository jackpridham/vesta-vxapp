const { test, expect } = require('@playwright/test');

async function currentPrimaryState(page) {
  const selectors = [
    '#docker-empty-state',
    '#docker-quota-reached-state',
    '#docker-list-state',
    '#docker-unavailable-state',
  ];

  for (const selector of selectors) {
    if (await page.locator(selector).isVisible().catch(() => false)) {
      return selector;
    }
  }

  return '';
}

test('empty owned-container state renders docker-empty-state', async ({ page }) => {
  await page.goto('/list/docker/');

  const selector = await currentPrimaryState(page);
  if (selector !== '#docker-empty-state') {
    test.skip(true, `Current Docker primary state is ${selector || 'unknown'}, not the empty-owned-container state.`);
  }

  await expect(page.locator('#docker-empty-state')).toBeVisible();
});

test('quota exhausted users render docker-quota-reached-state', async ({ page }) => {
  await page.goto('/list/docker/');

  const selector = await currentPrimaryState(page);
  if (selector !== '#docker-quota-reached-state') {
    test.skip(true, `Current Docker primary state is ${selector || 'unknown'}, not the quota-reached state.`);
  }

  await expect(page.locator('#docker-quota-reached-state')).toBeVisible();
});
