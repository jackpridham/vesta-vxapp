const { test, expect } = require('@playwright/test');

async function openDockerActions(page) {
  const dockerMore = page.locator('#docker-list-cards article[id^="docker-card-"] .actions-panel__logs a').first();
  if (!(await dockerMore.count())) {
    test.skip(true, 'Modal coverage requires at least one owned Docker container.');
  }

  await dockerMore.click();
  await expect(page.locator('#floating-center-div')).toBeVisible();
}

test('docker logs and inspect modals open and Escape closes the active modal', async ({ page }) => {
  await page.goto('/list/docker/');

  if (await page.locator('#docker-list-state').isHidden().catch(() => true)) {
    test.skip(true, 'Modal coverage requires the Docker list state.');
  }

  await openDockerActions(page);
  await page.getByRole('button', { name: /View Docker Logs/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container logs/i);

  await page.keyboard.press('Escape');
  await expect(page.locator('#floating-center-div')).toBeHidden();

  await openDockerActions(page);
  await page.getByRole('button', { name: /Inspect Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker container inspect/i);
});

test('docker remove modal supports cancel and confirm flows', async ({ page }) => {
  await page.route('**/ajax/docker/router.php', async (route) => {
    const postData = route.request().postData() || '';

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

  await page.goto('/list/docker/');

  if (await page.locator('#docker-list-state').isHidden().catch(() => true)) {
    test.skip(true, 'Remove modal coverage requires the Docker list state.');
  }

  await openDockerActions(page);
  await page.getByRole('button', { name: /Remove Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

  await page.getByRole('button', { name: /^No$/i }).click();
  await expect(page.locator('#floating-center-div')).toBeHidden();

  await openDockerActions(page);
  await page.getByRole('button', { name: /Remove Docker Container/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/remove Docker container/i);

  await page.getByRole('button', { name: /^Yes$/i }).click();
  await expect(page.locator('#floating-center-div-content')).toContainText(/Docker remove output/i);
});
