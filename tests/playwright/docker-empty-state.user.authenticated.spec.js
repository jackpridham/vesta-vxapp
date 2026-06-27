const { test, expect } = require('@playwright/test');
const { loginWithPassword, getOptionalEnv } = require('./helpers/panel-auth');

async function loginForSeededState(page, userEnv, passwordEnv) {
  const username = getOptionalEnv(userEnv);
  const password = getOptionalEnv(passwordEnv);

  test.skip(!username || !password, `This state test requires ${userEnv} and ${passwordEnv}.`);
  await loginWithPassword(page, { username, password });
}

async function assertPrimaryState(page, selector) {
  await page.goto('/list/docker/');
  await expect(page.locator(selector)).toBeVisible();
  await expect(page.locator('#docker-list-state')).toBeHidden();
}

test('empty owned-container state renders docker-empty-state', async ({ page }) => {
  await loginForSeededState(page, 'PLAYWRIGHT_DOCKER_EMPTY_USER', 'PLAYWRIGHT_DOCKER_EMPTY_PASSWORD');
  await assertPrimaryState(page, '#docker-empty-state');
  await expect(page.locator('#docker-empty-state')).toBeVisible();
  await expect(page.locator('#docker-quota-reached-state')).toBeHidden();
});

test('quota exhausted users render docker-quota-reached-state', async ({ page }) => {
  await loginForSeededState(page, 'PLAYWRIGHT_DOCKER_QUOTA_USER', 'PLAYWRIGHT_DOCKER_QUOTA_PASSWORD');
  await assertPrimaryState(page, '#docker-quota-reached-state');
  await expect(page.locator('#docker-quota-reached-state')).toBeVisible();
  await expect(page.locator('#docker-empty-state')).toBeHidden();
});
