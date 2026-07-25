const { test, expect } = require('@playwright/test');
const {
  getOptionalEnv,
  getPanelCredentials,
  readSessionToken,
} = require('./helpers/panel-auth');
const {
  composeProjectDefinition,
  createComposeProject,
  deleteContainer,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
} = require('./helpers/docker-runtime-fixtures');

test('non-admin cannot open either advanced Compose editor', async ({ page }) => {
  const owner = getPanelCredentials('dockerUser').username;

  await page.goto(`/add/docker/project/?user=${encodeURIComponent(owner)}`);
  await expect(page).toHaveURL(/\/list\/docker\/?$/);
  await expect(page.locator('body')).toContainText(/Advanced Compose definitions are admin-only/i);
  await expect(page.locator('#compose-advanced-add-form')).toHaveCount(0);

  await page.goto(`/edit/docker/project/?project=pw-denied&user=${encodeURIComponent(owner)}`);
  await expect(page).toHaveURL(/\/list\/docker\/?$/);
  await expect(page.locator('body')).toContainText(/Advanced Compose updates are admin-only/i);
  await expect(page.locator('#compose-advanced-update-form')).toHaveCount(0);
});

test('non-admin detail and AJAX requests cannot cross owner scope', async ({ page }) => {
  test.setTimeout(180_000);
  test.skip(
    !(hasLocalVestaRuntime() || hasRemoteVestaRuntime()) || !isLocalPanelTarget(),
    'Cross-owner coverage requires the configured panel and exact Vesta runtime target.'
  );

  const otherOwner = getOptionalEnv(
    'PLAYWRIGHT_DOCKER_EMPTY_USER',
    getPanelCredentials('admin').username
  );
  const project = `pw-cross-${Date.now().toString(36)}`;
  try {
    createComposeProject(
      otherOwner,
      project,
      composeProjectDefinition({ services: ['web'] }),
      { deploy: false }
    );

    await page.goto(
      `/list/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(otherOwner)}`
    );
    await expect(page).toHaveURL(/\/list\/docker\/?$/);
    await expect(page.locator('body')).toContainText(/does not exist or is not accessible/i);

    const token = await readSessionToken(page);
    const response = await page.request.post('/ajax/docker/index.php', {
      form: {
        token,
        'dataset[owner]': otherOwner,
        'dataset[project]': project,
        'dataset[container_name]': project,
      },
    });
    expect(await response.text()).toMatch(/do not have access/i);

    await page.goto('/list/docker/');
    await expect(
      page.locator(`#docker-list-cards article[data-owner="${otherOwner}"][data-name="${project}"]`)
    ).toHaveCount(0);
  } finally {
    deleteContainer(otherOwner, project);
  }
});

test('Compose list and project detail expose multi-service and revision context', async ({ page }) => {
  await page.goto('/list/docker/');

  test.skip(
    await page.locator('#docker-unavailable-state').isVisible().catch(() => false),
    'Compose project coverage requires Docker to be available.'
  );
  test.skip(
    await page.locator('#docker-empty-state').isVisible().catch(() => false),
    'Compose project coverage requires a seeded project.'
  );

  await expect(page.getByRole('heading', { name: /Compose projects/i })).toBeVisible();
  const card = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await card.count()) === 0, 'Compose project coverage requires a visible project card.');

  await expect(card).toContainText(/Services/i);
  await expect(card).toContainText(/Revision/i);
  await card.hover();
  await expect(card.getByRole('link', { name: /details/i })).toBeVisible();
  await card.getByRole('link', { name: /details/i }).click();

  await expect(page).toHaveURL(/\/list\/docker\/project\/\?project=/);
  await expect(page.getByText(/Docker Compose project/i).first()).toBeVisible();
  await expect(page.getByRole('heading', { name: /Services and immutable images/i })).toBeVisible();
  await expect(page.getByRole('heading', { name: /Audit trail/i })).toBeVisible();
  await expect(page.getByRole('heading', { name: /Managed backups/i })).toBeVisible();
});

test('Compose project actions expose redacted inspection and guarded lifecycle workflows', async ({ page }) => {
  await page.goto('/list/docker/');
  const card = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  test.skip((await card.count()) === 0, 'Compose modal coverage requires a seeded project.');

  await card.hover();
  await expect(card.getByRole('link', { name: /Project actions/i })).toBeVisible();
  await card.getByRole('link', { name: /Project actions/i }).click();
  const modal = page.locator('#floating-center-div-content');
  await expect(modal).toContainText(/Project summary/i);
  await expect(modal).toContainText(/Secret metadata/i);
  await expect(modal).toContainText(/Rollback revision/i);
  await expect(modal).toContainText(/Create backup/i);
  await expect(modal).toContainText(/Restore backup/i);
  await expect(modal).toContainText(/Remove project \(keep data\)/i);
});
