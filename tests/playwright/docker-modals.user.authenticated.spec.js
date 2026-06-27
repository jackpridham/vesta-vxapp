const { test, expect } = require('@playwright/test');

async function requireRealDockerRow(page) {
  await page.goto('/list/docker/');

  test.skip(await page.locator('#docker-unavailable-state').isVisible().catch(() => false), 'Docker engine is unavailable for modal coverage.');
  test.skip(await page.locator('#docker-empty-state').isVisible().catch(() => false), 'Modal coverage requires a seeded Docker container.');
  test.skip(await page.locator('#docker-quota-reached-state').isVisible().catch(() => false), 'Modal coverage requires at least one visible Docker container.');

  const row = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await row.count()) === 0, 'Modal coverage requires at least one visible Docker container.');
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

async function openDockerActions(page) {
  const rowData = await requireRealDockerRow(page);
  await rowData.dockerAction.click();
  await expect(page.locator('#floating-center-div')).toBeVisible();
  return rowData;
}

test('docker logs and inspect modals open and Escape closes the active modal', async ({ page }) => {
  let selectedRow = null;

  await page.route('**/ajax/docker/router.php', async (route) => {
    const postData = route.request().postData() || '';
    const params = new URLSearchParams(postData);

    if (selectedRow) {
      if (params.get('dataset[owner]') !== selectedRow.owner || params.get('dataset[container_name]') !== selectedRow.name) {
        await route.fulfill({
          status: 400,
          contentType: 'text/plain',
          body: 'unexpected docker modal dataset payload',
        });
        return;
      }
    }

    if (postData.includes('docker_logs=View+Docker+Logs')) {
      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: '<b>Docker container logs:</b><br /><br /><textarea id="confirm-div-content-textarea-variable" disabled>seeded log output</textarea>',
      });
      return;
    }

    if (postData.includes('docker_inspect=Inspect+Docker+Container')) {
      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: '<b>Docker container inspect:</b><br /><br /><textarea id="confirm-div-content-textarea-variable" disabled>{"Name":"seeded-app"}</textarea>',
      });
      return;
    }

    await route.continue();
  });

  selectedRow = await openDockerActions(page);
  await page.getByRole('button', { name: /View Docker Logs/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container logs/i);

  await page.keyboard.press('Escape');
  await expect(page.locator('#floating-center-div')).toBeHidden();

  selectedRow = await openDockerActions(page);
  await page.getByRole('button', { name: /Inspect Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container inspect/i);
});

test('docker remove modal supports cancel and confirm flows', async ({ page }) => {
  let selectedRow = null;

  await page.route('**/ajax/docker/router.php', async (route) => {
    const postData = route.request().postData() || '';
    const params = new URLSearchParams(postData);

    if (selectedRow) {
      if (params.get('dataset[owner]') !== selectedRow.owner || params.get('dataset[container_name]') !== selectedRow.name) {
        await route.fulfill({
          status: 400,
          contentType: 'text/plain',
          body: 'unexpected docker modal dataset payload',
        });
        return;
      }
    }

    if (postData.includes('docker_remove=Remove+Docker+Container')) {
      const owner = selectedRow ? selectedRow.owner : 'seeded-user';
      const name = selectedRow ? selectedRow.name : 'seeded-app';
      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: `
          <form id="floating-center-div-form" method="post" action="/ajax/docker/router.php">
            <input type="hidden" name="token" value="test-token" />
            <input type="hidden" name="dataset[owner]" value="${owner}" />
            <input type="hidden" name="dataset[container_name]" value="${name}" />
            <input type="hidden" name="docker_remove" value="1" />
            Are you sure you want to remove Docker container ${name}?<br /><br />
            <button type="submit" name="Yes" value="Yes">Yes</button>
            <button type="submit" name="No" value="No">No</button>
          </form>
        `,
      });
      return;
    }

    if (postData.includes('docker_remove=1') && postData.includes('No=No')) {
      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: '<script>hideFloatingDiv();</script>',
      });
      return;
    }

    if (postData.includes('docker_remove=1') && postData.includes('Yes=Yes')) {
      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: '<b>Docker remove output:</b><br /><br /><textarea id="confirm-div-content-textarea-variable" disabled>simulated remove</textarea>',
      });
      return;
    }

    await route.continue();
  });

  selectedRow = await openDockerActions(page);
  await page.getByRole('button', { name: /Remove Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

  await page.getByRole('button', { name: /^No$/i }).click();
  await expect(page.locator('#floating-center-div')).toBeHidden();

  selectedRow = await openDockerActions(page);
  await page.getByRole('button', { name: /Remove Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

  await page.getByRole('button', { name: /^Yes$/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker remove output/i);
});
