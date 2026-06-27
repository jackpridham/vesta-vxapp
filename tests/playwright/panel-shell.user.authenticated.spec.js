const { test, expect } = require('@playwright/test');
const { loginAsRole } = require('./helpers/panel-auth');

test('authenticated non-admin session reaches the user panel shell', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  await page.goto('/list/docker/');

  await expect(page.locator('.l-header')).toBeVisible();
  await expect(page.locator('#token')).toHaveAttribute('token', /.+/);
  await expect(page.locator('.l-profile__logout')).toBeVisible();
});
