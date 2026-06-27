const { test, expect } = require('@playwright/test');

test('authenticated admin session reaches the panel shell and session token surface', async ({ page }) => {
  await page.goto('/list/user/');

  await expect(page.locator('.l-header')).toBeVisible();
  await expect(page.locator('#token')).toHaveAttribute('token', /.+/);
  await expect(page.locator('.l-profile__logout')).toBeVisible();
});
