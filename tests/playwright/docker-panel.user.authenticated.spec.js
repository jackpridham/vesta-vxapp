const { test, expect } = require('@playwright/test');

test('non-admin docker pages render the user shell and docker forms', async ({ page }) => {
  await page.goto('/list/docker/');

  await expect(page.locator('.l-header')).toBeVisible();
  await expect(page.locator('#token')).toHaveAttribute('token', /.+/);

  const listVisible = await page.locator('#docker-list-state').isVisible().catch(() => false);
  const emptyVisible = await page.locator('#docker-empty-state').isVisible().catch(() => false);
  const unavailableVisible = await page.locator('#docker-unavailable-state').isVisible().catch(() => false);
  const quotaVisible = await page.locator('#docker-quota-reached-state').isVisible().catch(() => false);

  expect(listVisible || emptyVisible || unavailableVisible || quotaVisible).toBeTruthy();

  await page.goto('/add/docker/');
  await expect(page.locator('#docker-create-form')).toBeVisible();

  await page.goto('/list/docker/');
  const editLinks = page.locator('a[href*="/edit/docker/?container="]');
  if (await editLinks.count()) {
    await editLinks.first().click();
    await expect(page.locator('#docker-edit-form')).toBeVisible();
  }
});
