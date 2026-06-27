const { test, expect } = require('@playwright/test');
const { getOptionalEnv, getPanelCredentials, loginAsRole } = require('./helpers/panel-auth');
const { createDisposableContainer, deleteContainer, hasLocalVestaRuntime, hasRemoteVestaRuntime, isLocalPanelTarget } = require('./helpers/docker-runtime-fixtures');

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
  const floatingModal = page.locator('#floating-center-div').first();
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
  await expect(floatingModal).toBeVisible();
  return rowData;
}

test('docker logs and inspect modals open and Escape closes the active modal', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  const preferredContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_MODAL_CONTAINER');
  const floatingModal = page.locator('#floating-center-div').first();
  const floatingContent = page.locator('#floating-center-div-content').first();
  await openDockerActions(page, preferredContainer);
  await page.getByRole('button', { name: /View Docker Logs/i }).click();
  await expect(floatingContent).toContainText(/Docker container logs/i);
  await expect(floatingContent.locator('textarea')).toBeVisible();

  await page.keyboard.press('Escape');
  await expect(floatingModal).toBeHidden();

  await openDockerActions(page, preferredContainer);
  await page.getByRole('button', { name: /Inspect Docker Container/i }).click();
  await expect(floatingContent).toContainText(/Docker container inspect/i);
  await expect(floatingContent.locator('textarea')).toBeVisible();
});

test('docker remove modal supports cancel and confirm flows', async ({ page }) => {
  test.skip(!(hasLocalVestaRuntime() || hasRemoteVestaRuntime()), 'Remove-confirm coverage requires a reachable Vesta runtime target for disposable container setup.');
  test.skip(!isLocalPanelTarget(), 'Remove-confirm coverage requires the runtime target to match PLAYWRIGHT_BASE_URL.');

  await loginAsRole(page, 'dockerUser');
  const owner = getPanelCredentials('dockerUser').username;
  const image = getOptionalEnv('PLAYWRIGHT_DOCKER_TEST_IMAGE', 'busybox:1.36.1');
  let removableContainer = `pw-remove-${Date.now().toString(36)}`;
  let createdDisposable = false;
  const floatingModal = page.locator('#floating-center-div').first();
  const floatingContent = page.locator('#floating-center-div-content').first();

  try {
    await page.goto('/list/docker/');
    test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Remove-confirm coverage requires a host with Docker available.');
    const existingDisposable = page.locator('#docker-list-cards article[data-name^="pw-"]').first();
    if (await existingDisposable.count()) {
      removableContainer = (await existingDisposable.getAttribute('data-name')) || removableContainer;
    } else {
      test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Remove-confirm coverage requires quota headroom for a disposable container.');
      try {
        createDisposableContainer(owner, removableContainer, image);
        createdDisposable = true;
      } catch (error) {
        await page.goto('/list/docker/');
        const fallbackDisposable = page.locator('#docker-list-cards article[data-name^="pw-"]').first();
        if ((await fallbackDisposable.count()) === 0) {
          throw error;
        }
        removableContainer = (await fallbackDisposable.getAttribute('data-name')) || removableContainer;
      }
      await page.goto('/list/docker/');
    }

    await expect(page.locator(`#docker-list-cards article[data-name="${removableContainer}"]`)).toHaveCount(1);
    await openDockerActions(page, removableContainer);
    await page.getByRole('button', { name: /Remove Docker Container/i }).click();
    await expect(floatingContent).toContainText(/remove Docker container/i);

    await page.getByRole('button', { name: /^No$/i }).click();
    await expect(floatingModal).toBeHidden();

    await openDockerActions(page, removableContainer);
    await page.getByRole('button', { name: /Remove Docker Container/i }).click();
    await expect(floatingContent).toContainText(/remove Docker container/i);

    await page.getByRole('button', { name: /^Yes$/i }).click();
    await expect(floatingContent).toContainText(/Docker remove output/i);

    await page.goto('/list/docker/');
    await expect(page.locator(`#docker-list-cards article[data-name="${removableContainer}"]`)).toHaveCount(0);
  } finally {
    if (createdDisposable) {
      deleteContainer(owner, removableContainer);
    }
  }
});
