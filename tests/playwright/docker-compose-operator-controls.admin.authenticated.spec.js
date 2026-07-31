const { test, expect } = require('@playwright/test');
const { getPanelCredentials } = require('./helpers/panel-auth');
const {
  composeProjectDefinition,
  createComposeProject,
  deleteContainer,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  removeComposeServiceRuntime,
  runVestaCommand,
} = require('./helpers/docker-runtime-fixtures');

function readDrift(owner, project) {
  return JSON.parse(
    runVestaCommand('v-list-docker-project-drift', [
      'admin',
      owner,
      project,
      'json',
    ])
  );
}

function readOperation(owner, project) {
  return JSON.parse(
    runVestaCommand('v-list-docker-project-operation', [
      'admin',
      owner,
      project,
      'json',
    ])
  );
}

async function openProjectActions(page) {
  await page.getByRole('link', { name: /Project actions/i }).click();
  const modal = page.locator('#floating-center-div').first();
  await expect(modal).toBeVisible();
  await expect(modal.getByRole('button', { name: /Project summary/i })).toBeVisible();
  return modal;
}

async function closeProjectActions(page) {
  await page.keyboard.press('Escape');
  await expect(page.locator('#floating-center-div').first()).toBeHidden();
}

test('operator console observes drift, reconciles explicitly, and remains usable on narrow screens', async ({ page }) => {
  test.setTimeout(360_000);
  page.setDefaultTimeout(15_000);
  test.skip(
    !(hasLocalVestaRuntime() || hasRemoteVestaRuntime()) || !isLocalPanelTarget(),
    'Operator-control coverage requires the configured panel and exact Vesta runtime target.'
  );

  const owner = getPanelCredentials('dockerUser').username;
  const project = `pw-ops-${Date.now().toString(36)}`;

  try {
    createComposeProject(
      owner,
      project,
      composeProjectDefinition({ services: ['web', 'worker'] }),
      { deploy: true }
    );
    const archive = runVestaCommand('v-backup-docker-project', [owner, project]).trim();

    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto(`/list/docker/?user=${encodeURIComponent(owner)}`);
    const projectCard = page.locator(
      `#docker-list-cards article[data-owner="${owner}"][data-name="${project}"]`
    );
    await expect(projectCard).toBeVisible();
    await page.evaluate(() => window.VX_DOCKER_POLLING_TEST.refresh());
    await expect(projectCard.locator('.docker-card-health-badge')).toHaveAttribute(
      'data-freshness',
      /^(fresh|stale)$/
    );
    await projectCard.hover();
    await projectCard.getByRole('link', { name: /details/i }).click();
    await expect(page.getByRole('heading', { name: project })).toBeVisible();
    await expect(page.getByRole('heading', { name: /Desired\/runtime drift/i })).toBeVisible();
    await expect(page.getByRole('heading', { name: /Managed backups/i })).toBeVisible();
    await expect(page.getByText(archive, { exact: true })).toBeVisible();

    const advanced = page.locator('details.docker-advanced-json').first();
    await expect(advanced).not.toHaveAttribute('open', '');
    await advanced.getByText(/Advanced JSON/i).click();
    await expect(advanced.locator('pre')).toBeVisible();

    let modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Desired\/runtime drift/i }).click();
    await expect(modal).toContainText(/Runtime matches the validated desired revision/i);
    await closeProjectActions(page);

    removeComposeServiceRuntime(owner, project, 'worker');
    await expect.poll(
      () => readDrift(owner, project).MATCH,
      { timeout: 30_000 }
    ).toBe(false);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Desired\/runtime drift/i }).click();
    await expect(modal).toContainText(/Runtime differs/i);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Reconcile observed drift/i }).click();
    await expect(modal).toContainText(/Reconcile runtime to revision 1/i);
    await expect(modal.getByText(/Advanced JSON/i)).toBeVisible();
    await modal.getByRole('button', { name: /^Yes$/i }).click();
    await expect(modal).toContainText(/Compose reconcile output/i);
    await expect(modal.locator('textarea')).toBeVisible();
    await expect.poll(
      () => readDrift(owner, project).MATCH,
      { timeout: 90_000 }
    ).toBe(true);
    await expect.poll(
      () => {
        const operation = readOperation(owner, project);
        return `${operation.ACTION}:${operation.RESULT}:${operation.PERCENT}`;
      },
      { timeout: 30_000 }
    ).toBe('reconcile:succeeded:100');
    await closeProjectActions(page);

    await page.setViewportSize({ width: 390, height: 844 });
    await page.reload();
    await expect(page.getByRole('heading', { name: project })).toBeVisible();
    const heroBounds = await page.locator('.docker-hero').boundingBox();
    expect(heroBounds).not.toBeNull();
    expect(heroBounds.height).toBeLessThan(280);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
      .toBe(true);
    modal = await openProjectActions(page);
    const bounds = await modal.boundingBox();
    expect(bounds).not.toBeNull();
    expect(bounds.x).toBeGreaterThanOrEqual(0);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(390);
    expect(bounds.y).toBeGreaterThanOrEqual(0);
    expect(bounds.y + bounds.height).toBeLessThanOrEqual(844);
    await modal.getByRole('button', { name: /View project logs/i }).click();
    await expect(modal.getByRole('button', { name: /View logs/i })).toBeVisible();
  } finally {
    deleteContainer(owner, project);
  }
});
