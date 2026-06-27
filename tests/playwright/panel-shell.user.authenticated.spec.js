const { test, expect } = require('@playwright/test');

test('authenticated non-admin session reaches the user panel shell', async ({ page }) => {
  await page.goto('/list/web/');

  await expect(page.locator('.l-header')).toBeVisible();
  await expect(page.locator('#token')).toHaveAttribute('token', /.+/);
  await expect(page.locator('.l-profile__logout')).toBeVisible();
});
