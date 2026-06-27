const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');

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
  const onclick = (await dockerAction.getAttribute('onclick')) || '';
  const match = onclick.match(/more_button_click\((\d+)\)/);
  const datasetIndex = match ? Number(match[1]) : NaN;

  expect(owner).not.toBe('');
  expect(name).not.toBe('');
  expect(Number.isNaN(datasetIndex)).toBeFalsy();

  const datasetEntry = await page.evaluate((index) => {
    return window.dataset_values && window.dataset_values[index]
      ? {
          owner: window.dataset_values[index].owner,
          containerName: window.dataset_values[index].container_name,
          title: window.dataset_values[index].title,
        }
      : null;
  }, datasetIndex);

  expect(datasetEntry).not.toBeNull();
  expect(datasetEntry.owner).toBe(owner);
  expect(datasetEntry.containerName).toBe(name);

  return { row, owner, name, dockerAction };
}

async function openDockerActions(page, preferredContainer = '') {
  const rowData = await requireRealDockerRow(page, preferredContainer);
  await rowData.dockerAction.click();
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
  const removableContainer = getOptionalEnv('PLAYWRIGHT_DOCKER_REMOVE_CONTAINER');
  test.skip(!removableContainer, 'Remove-confirm coverage requires PLAYWRIGHT_DOCKER_REMOVE_CONTAINER to target a disposable seeded container that is reseeded between runs.');

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
});
