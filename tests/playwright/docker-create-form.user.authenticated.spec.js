const { test, expect } = require('@playwright/test');
const { getOptionalEnv, getPanelCredentials, loginAsRole } = require('./helpers/panel-auth');
const {
  deleteContainer,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  runVestaCommand,
} = require('./helpers/docker-runtime-fixtures');

const contractedFields = [
  'v_container_name',
  'v_container_image',
  'v_container_command',
  'v_container_env',
  'v_container_mounts',
  'v_container_port',
  'v_route_domain',
  'v_route_path',
  'v_auto_start',
  'v_restart_policy',
  'v_healthcheck_type',
  'v_healthcheck_target',
  'v_healthcheck_interval',
  'v_cpu_alert_pct',
  'v_mem_alert_mb',
  'v_net_alert_mbps',
  'v_alert_email',
];

async function cleanupContainer(page, name) {
  const deleteLink = page.locator(`a[href*="/delete/docker/?container=${encodeURIComponent(name)}"]`).first();
  if (!(await deleteLink.count())) {
    return;
  }

  await deleteLink.click();
  await expect(page).toHaveURL(/\/list\/docker\/?$/);
  await expect(page.locator(`a[href*="/delete/docker/?container=${encodeURIComponent(name)}"]`)).toHaveCount(0);
}

test('docker add form renders contracted field names and validation errors inside docker-form-errors', async ({ page }) => {
  await loginAsRole(page, 'dockerUser');
  await page.goto('/add/docker/');

  const form = page.locator('#docker-create-form');
  await expect(form).toBeVisible();

  for (const field of contractedFields) {
    await expect(form.locator(`[name="${field}"]`)).toHaveCount(1);
  }

  await form.locator('[name="v_container_name"]').fill('');
  await form.locator('[name="v_container_image"]').fill('');
  await form.locator('[name="v_container_port"]').fill('');
  await page.getByRole('button', { name: /^Add$/i }).click();

  await expect(page).toHaveURL(/\/add\/docker\/?$/);
  await expect(page.locator('#docker-form-errors')).toContainText(/\S+/);
});

test('successful create streams the spawned job and reaches the docker list', async ({ page }) => {
  test.setTimeout(120_000);
  const image = getOptionalEnv('PLAYWRIGHT_DOCKER_TEST_IMAGE', 'busybox:1.36.1');
  const name = `pw-${Date.now().toString(36)}`;
  const pageErrors = [];
  const watcherResponses = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('response', (response) => {
    if (new URL(response.url()).pathname === '/ajax/watch-spawned-ajax-process.php') {
      watcherResponses.push(response.json().then(
        (body) => ({ body, status: response.status() }),
        () => ({ body: null, status: response.status() })
      ));
    }
  });

  try {
    await loginAsRole(page, 'dockerUser');
    await page.goto('/list/docker/');
    if (await page.locator('#docker-unavailable-state').isVisible().catch(() => false)) {
      test.skip(true, 'Docker engine is unavailable for create coverage.');
    }
    if (await page.locator('#docker-quota-reached-state').isVisible().catch(() => false)) {
      test.skip(true, 'The authenticated Docker user is already at quota.');
    }

    await page.goto('/add/docker/');
    await expect(page.locator('#docker-create-form')).toBeVisible();

    await page.locator('[name="v_container_name"]').fill(name);
    await page.locator('[name="v_container_image"]').fill(image);
    await page.locator('[name="v_container_command"]').fill('sleep 3600');
    await page.locator('[name="v_container_env"]').fill('MODE=playwright');
    await page.locator('[name="v_container_mounts"]').fill('data:/data');
    await page.locator('[name="v_container_port"]').fill('8080');
    await page.locator('[name="v_route_domain"]').selectOption('');
    await page.locator('[name="v_route_path"]').fill('');
    await page.locator('[name="v_restart_policy"]').selectOption('unless-stopped');
    await page.locator('[name="v_healthcheck_type"]').selectOption('none');
    await page.locator('[name="v_healthcheck_target"]').fill('');
    await page.locator('[name="v_healthcheck_interval"]').fill('60');
    await page.locator('[name="v_cpu_alert_pct"]').fill('85');
    await page.locator('[name="v_mem_alert_mb"]').fill('1024');
    await page.locator('[name="v_net_alert_mbps"]').fill('50');

    if (await page.locator('[name="v_auto_start"]').isChecked()) {
      await page.locator('[name="v_auto_start"]').evaluate((element) => {
        element.checked = false;
        element.dispatchEvent(new Event('change', { bubbles: true }));
      });
    }

    if (!(await page.locator('[name="v_alert_email"]').isChecked())) {
      await page.locator('[name="v_alert_email"]').evaluate((element) => {
        element.checked = true;
        element.dispatchEvent(new Event('change', { bubbles: true }));
      });
    }

    await page.getByRole('button', { name: /^Add$/i }).click();
    await expect(page).toHaveURL(/\/add\/docker\/?$/);
    await expect(page.locator('#docker-simple-spawn-output')).toBeVisible();
    const output = page.locator('#docker-simple-spawn-output textarea');
    await expect(output).toBeVisible();
    await expect.poll(
      () => watcherResponses.length,
      { message: `spawn watcher did not poll; page errors: ${pageErrors.join('; ')}` }
    ).toBeGreaterThan(0);
    await expect.poll(async () => {
      const responses = await Promise.all(watcherResponses);
      return responses.some(({ body, status }) =>
        status === 200 && body && Number(body.code) > 0
      );
    }, { timeout: 120_000 }).toBe(true);
    await expect.poll(() => {
      try {
        const project = JSON.parse(
          runVestaCommand(
            'v-list-docker-project',
            [getPanelCredentials('dockerUser').username, name, 'json']
          )
        );
        return project.PROJECT || '';
      } catch {
        return '';
      }
    }, { timeout: 120_000 }).toBe(name);

    await page.goto('/list/docker/');
    await expect(page.locator(`#docker-list-cards article[data-name="${name}"]`)).toHaveCount(1);
    await expect(page.locator(`#docker-list-cards article[data-name="${name}"]`).first()).toBeVisible();
    expect(pageErrors).toEqual([]);
  } finally {
    if ((hasLocalVestaRuntime() || hasRemoteVestaRuntime()) && isLocalPanelTarget()) {
      deleteContainer(getPanelCredentials('dockerUser').username, name);
    } else {
      if (page.isClosed()) {
        return;
      }
      await page.goto('/list/docker/');
      await cleanupContainer(page, name);
    }
  }
});
