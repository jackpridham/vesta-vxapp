const { test, expect } = require('@playwright/test');

async function ensureModalFixture(page) {
  await page.evaluate(() => {
    const listState = document.querySelector('#docker-list-state');
    const cards = document.querySelector('#docker-list-cards');

    if (listState) {
      listState.style.display = '';
    }

    window.dataset_values = window.dataset_values || [];
    window.dataset_values[999] = {
      url: '/ajax/docker/index.php',
      title: 'fixture-app',
      container_name: 'fixture-app',
      owner: 'dockeruser',
    };

    if (!cards) {
      return;
    }

    if (!cards.querySelector('[data-playwright-modal="yes"]')) {
      const article = document.createElement('article');
      article.id = 'docker-card-dockeruser-fixture-app';
      article.dataset.owner = 'dockeruser';
      article.dataset.name = 'fixture-app';
      article.dataset.playwrightModal = 'yes';
      article.innerHTML = `
        <div class="actions-panel clearfix">
          <div class="actions-panel__col actions-panel__logs">
            <a href="javascript:void(0)" onclick="more_button_click(999)">Docker</a>
          </div>
        </div>
      `;
      cards.prepend(article);
    }
  });
}

async function openDockerActions(page) {
  await ensureModalFixture(page);
  const dockerMore = page.locator('#docker-list-cards article[data-playwright-modal="yes"] .actions-panel__logs a').first();
  await dockerMore.click();
  await expect(page.locator('#floating-center-div')).toBeVisible();
}

test('docker logs and inspect modals open and Escape closes the active modal', async ({ page }) => {
  await page.goto('/list/docker/');

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
