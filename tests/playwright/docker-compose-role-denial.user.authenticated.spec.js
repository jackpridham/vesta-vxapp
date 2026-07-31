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
  readComposeProject,
  runVestaCommand,
} = require('./helpers/docker-runtime-fixtures');

test('delegated viewer sees read evidence while mutation controls and direct requests fail closed', async ({ page }) => {
  test.setTimeout(240_000);
  page.setDefaultTimeout(15_000);
  test.skip(
    !(hasLocalVestaRuntime() || hasRemoteVestaRuntime()) || !isLocalPanelTarget(),
    'Role-denial coverage requires the configured panel and exact Vesta runtime target.'
  );

  const actor = getPanelCredentials('dockerUser').username;
  const owner = getOptionalEnv('PLAYWRIGHT_DOCKER_EMPTY_USER', '');
  test.skip(!owner || owner === actor, 'Role-denial coverage requires a distinct disposable owner.');
  const project = `pw-view-${Date.now().toString(36)}`;

  try {
    createComposeProject(
      owner,
      project,
      composeProjectDefinition({ services: ['web'] }),
      { deploy: true }
    );
    runVestaCommand('v-add-docker-project-role', [
      'admin',
      owner,
      project,
      actor,
      'viewer',
    ]);

    await page.goto(
      `/list/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
    );
    await expect(page.getByRole('heading', { name: project })).toBeVisible();
    await expect(page.getByRole('link', { name: /Advanced update/i })).toHaveCount(0);
    await expect(page.getByRole('link', { name: /Restart project/i })).toHaveCount(0);

    await page.getByRole('link', { name: /Project actions/i }).click();
    const modal = page.locator('#floating-center-div').first();
    await expect(modal.getByRole('button', { name: /Project summary/i })).toBeVisible();
    await expect(modal.getByRole('button', { name: /Desired\/runtime drift/i })).toBeVisible();
    await expect(modal.getByRole('button', { name: /Project roles/i })).toBeVisible();
    for (const denied of [
      /Recreate service/i,
      /Deploy validated revision/i,
      /Rollback revision/i,
      /Create backup/i,
      /Restore backup/i,
      /Reconcile observed drift/i,
      /Remove project/i,
    ]) {
      await expect(modal.getByRole('button', { name: denied })).toHaveCount(0);
    }

    const token = await readSessionToken(page);
    const before = readComposeProject(owner, project);
    const denied = await page.request.post('/ajax/docker/router.php', {
      form: {
        token,
        docker_recreate: '1',
        'dataset[owner]': owner,
        'dataset[project]': project,
        'dataset[container_name]': project,
      },
    });
    expect(await denied.text()).toMatch(/do not have access/i);
    const after = readComposeProject(owner, project);
    expect(`${after.STATE}:${after.REVISION}`).toBe(`${before.STATE}:${before.REVISION}`);

    runVestaCommand('v-delete-docker-project-role', [
      'admin',
      owner,
      project,
      actor,
    ]);
    await page.goto(
      `/list/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
    );
    await expect(page).toHaveURL(/\/list\/docker\/?$/);
    await expect(page.locator('body')).toContainText(/does not exist or is not accessible/i);
  } finally {
    deleteContainer(owner, project);
  }
});
