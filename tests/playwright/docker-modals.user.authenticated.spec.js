const { test, expect } = require('@playwright/test');
const { getOptionalEnv, getPanelCredentials } = require('./helpers/panel-auth');
const { createDisposableContainer, deleteContainer, hasLocalVestaRuntime, isLocalPanelTarget } = require('./helpers/docker-runtime-fixtures');

async function requireRealDockerRow(page, preferredContainer = '') {
  await page.goto('/list/docker/');

  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Docker engine is unavailable for modal coverage.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Modal coverage requires a seeded Docker container.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Modal coverage requires at least one visible Docker container.');

  const row = preferredContainer
    ? page.locator(`#docker-list-cards article[data-name="${preferredContainer}"]`).first()
    : page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await row.count()) === 0, preferredContainer
    ? `Modal coverage requires seeded container "${preferredContainer}".`
    : 'Modal coverage requires at least one visible Docker container.');
  await expect(row).toBeVisible();

  const owner = (await row.getAttribute('data-owner')) || '';
  const name = (await row.getAttribute('data-name')) || '';
  const dockerAction = row.locator('.actions-panel__logs a').first();

  expect(owner).not.toBe('');
  expect(name).not.toBe('');
  await expect(dockerAction).toBeVisible();

  return { row, owner, name, dockerAction };
}

async function openDockerActions(page, preferredContainer = '') {
  const rowData = await requireRealDockerRow(page, preferredContainer);
  const [request] = await Promise.all([
    page.waitForRequest((candidate) => {
      if (!candidate.url().includes('/ajax/docker/index.php')) {
        return false;
      }

      const params = new URLSearchParams(candidate.postData() || '');
      return params.get('dataset[owner]') === rowData.owner
        && params.get('dataset[container_name]') === rowData.name;
    }),
    rowData.dockerAction.click(),
  ]);
  const requestParams = new URLSearchParams(request.postData() || '');
  expect(requestParams.get('dataset[owner]')).toBe(rowData.owner);
  expect(requestParams.get('dataset[container_name]')).toBe(rowData.name);
  await expect(page.locator('#floating-center-div')).toBeVisible();
  return rowData;
}

test('docker logs and inspect modals open and Escape closes the active modal', async ({ page }) => {
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_MODAL_CONTAINER');
  await openDockerActions(page, preferredContainer);
  await page.getByRole('button', { name: /View Docker Logs/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container logs/i);
  await expect(page.locator('#floating-center-div-content textarea')).toBeVisible();

  await page.keyboard.press('Escape');
  await expect(page.locator('#floating-center-div')).toBeHidden();

  await openDockerActions(page, preferredContainer);
  await page.getByRole('button', { name: /Inspect Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container inspect/i);
  await expect(page.locator('#floating-center-div-content textarea')).toBeVisible();
});

test('docker remove modal supports cancel and confirm flows', async ({ page }) => {
  test.skip(!hasLocalVestaRuntime(), 'Remove-confirm coverage requires local Vesta runtime access for disposable container setup.');
  test.skip(!isLocalPanelTarget(), 'Remove-confirm coverage requires PLAYWRIGHT_BASE_URL to target the same host as the local Vesta runtime.');

  const owner = getPanelCredentials('dockerUser').username;
  const image = getOptionalEnv('PLAYWRIGHT_DOCKER_TEST_IMAGE', 'busybox:1.36.1');
  const removableContainer = `pw-remove-${Date.now().toString(36)}`;

  try {
    await page.goto('/list/docker/');
    test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Remove-confirm coverage requires a host with Docker available.');
    test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Remove-confirm coverage requires quota headroom for a disposable container.');

    createDisposableContainer(owner, removableContainer, image);
    await page.goto('/list/docker/');
    await expect(page.locator(`#docker-list-cards article[data-name="${removableContainer}"]`)).toHaveCount(1);
    await openDockerActions(page, removableContainer);
    await page.getByRole('button', { name: /Remove Docker Container/i }).click();
    await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

    await page.getByRole('button', { name: /^No$/i }).click();
    await expect(page.locator('#floating-center-div')).toBeHidden();

    await openDockerActions(page, removableContainer);
    await page.getByRole('button', { name: /Remove Docker Container/i }).click();
    await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

    await page.getByRole('button', { name: /^Yes$/i }).click();
    await expect(page.locator('#floating-center-div-content')).toContainText(/Docker remove output/i);

    await page.goto('/list/docker/');
    await expect(page.locator(`#docker-list-cards article[data-name="${removableContainer}"]`)).toHaveCount(0);
  } finally {
    deleteContainer(owner, removableContainer);
  }
});
