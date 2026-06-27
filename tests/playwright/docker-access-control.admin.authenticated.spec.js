const { test, expect } = require('@playwright/test');
const { getOptionalEnv, switchLookUser } = require('./helpers/panel-auth');

test('admin server navigation still exposes the docker page', async ({ page }) => {
  await page.goto('/list/server/');

  const dockerLink = page.locator('a[href="/list/docker/"]').filter({ hasText: /docker/i }).first();
  await expect(dockerLink).toBeVisible();
});

test('admin docker list shows owner-aware rows and can pivot by owner when multiple owners exist', async ({ page }) => {
  await page.goto('/list/docker/');

  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Admin owner-filter coverage requires Docker to be available.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Admin owner-filter coverage requires seeded Docker containers for multiple owners.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Admin owner-filter coverage requires a visible multi-owner Docker list state.');

  await expect(page.locator('#docker-owner-filter')).toContainText(/Owner scope/i);

  const ownerSelect = page.locator('form[action="/list/docker/"] select[name="user"]');
  const optionValues = (await Promise.all(
    (await ownerSelect.locator('option').all()).map(async (option) => option.getAttribute('value'))
  )).filter((value) => value);
  test.skip(optionValues.length < 2, 'Admin owner-filter coverage requires seeded Docker containers for at least two owners.');
  const currentOwner = await ownerSelect.inputValue();

  const firstCard = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  await expect(firstCard).toBeVisible();
  await expect(firstCard).toHaveAttribute('data-owner', /.+/);
  await expect(firstCard).toContainText(/Owner/i);

  const preferredOwner = getOptionalEnv('PLAYWRIGHT_DOCKER_OWNER_FILTER_USER');
  const pivotOwner = optionValues.find((value) => value === preferredOwner && value !== currentOwner)
    || optionValues.find((value) => value !== currentOwner)
    || '';
  test.skip(!pivotOwner, 'Admin owner-filter coverage requires a second owner distinct from the current scope.');

  await ownerSelect.selectOption(pivotOwner);
  await expect(page).toHaveURL(new RegExp(`/list/docker/\\?user=${encodeURIComponent(pivotOwner)}`));
  await expect(page.locator('#docker-owner-filter')).toContainText(new RegExp(`Owner scope.*${pivotOwner}`, 'i'));

  const filteredCards = page.locator('#docker-list-cards article[id^="docker-card-"]');
  const owners = await Promise.all(
    (await filteredCards.all()).map(async (card) => (await card.getAttribute('data-owner')) || '')
  );
  expect(owners.length).toBeGreaterThan(0);
  expect(owners.every((owner) => owner === pivotOwner)).toBeTruthy();
});

test('admin login-as user does not expose all-user docker scope', async ({ page }) => {
  const lookedUser = getOptionalEnv('PLAYWRIGHT_DOCKER_USER');
  test.skip(!lookedUser, 'Admin login-as coverage requires PLAYWRIGHT_DOCKER_USER.');

  await page.goto('/list/user/');
  await switchLookUser(page, lookedUser);
  await page.goto('/list/docker/');

  await expect(page.locator('#docker-owner-filter')).not.toContainText(/Owner scope/i);
  await expect(page.locator('form[action="/list/docker/"] select[name="user"]')).toHaveCount(0);

  const visibleCards = page.locator('#docker-list-cards article[id^="docker-card-"]');
  const owners = await Promise.all(
    (await visibleCards.all()).map(async (card) => (await card.getAttribute('data-owner')) || '')
  );

  expect(owners.every((owner) => owner === '' || owner === lookedUser)).toBeTruthy();
});
