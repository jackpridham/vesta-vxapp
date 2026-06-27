const { test, expect } = require('@playwright/test');
const { openPanelLogin } = require('./helpers/panel-auth');

test('login page exposes the expected form and CSRF token', async ({ page }) => {
  await openPanelLogin(page);

  await expect(page.locator('form[action="/login/"]')).toBeVisible();
  await expect(page.locator('input[name="token"]')).toHaveAttribute('value', /.+/);
  await expect(page.locator('input[name="user"]')).toBeVisible();
  await expect(page.locator('input[name="password"]')).toBeVisible();
  await expect(page.getByRole('button', { name: /log in/i })).toBeVisible();
});
