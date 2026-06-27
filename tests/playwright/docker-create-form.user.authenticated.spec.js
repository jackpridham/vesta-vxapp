const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');

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
  await page.waitForLoadState('networkidle');
  await expect(page).toHaveURL(/\/list\/docker\/?$/);
  await expect(page.locator(`a[href*="/delete/docker/?container=${encodeURIComponent(name)}"]`)).toHaveCount(0);
}

test('docker add form renders contracted field names and validation errors inside docker-form-errors', async ({ page }) => {
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

test('successful create redirects back to the docker list', async ({ page }) => {
  const image = getOptionalEnv('PLAYWRIGHT_DOCKER_TEST_IMAGE', 'busybox:1.36.1');
  const name = `pw-${Date.now().toString(36)}`;

  try {
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
      await page.locator('[name="v_auto_start"]').uncheck();
    }

    if (!(await page.locator('[name="v_alert_email"]').isChecked())) {
      await page.locator('[name="v_alert_email"]').check();
    }

    await page.getByRole('button', { name: /^Add$/i }).click();
    await page.waitForLoadState('networkidle');

    const errorText = ((await page.locator('#docker-form-errors').textContent()) || '').trim();
    expect(
      /\/list\/docker\/?$/.test(page.url()),
      `Create did not redirect back to /list/docker/. Form errors: ${errorText || '[none]'}`,
    ).toBeTruthy();
    await expect(page.locator(`#docker-list-cards article[data-name="${name}"]`)).toHaveCount(1);
    await expect(page.locator(`#docker-list-cards article[data-name="${name}"]`).first()).toBeVisible();
  } finally {
    await page.goto('/list/docker/');
    await cleanupContainer(page, name);
  }
});
