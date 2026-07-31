const { test, expect } = require('@playwright/test');
const {
  getPanelCredentials,
  readSessionToken,
} = require('./helpers/panel-auth');
const {
  addComposeProjectSecret,
  composeProjectDefinition,
  deleteContainer,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  managedSecretPath,
  runVestaCommand,
} = require('./helpers/docker-runtime-fixtures');

function readProject(owner, project) {
  try {
    return JSON.parse(runVestaCommand('v-list-docker-project', [owner, project, 'json']));
  } catch {
    return null;
  }
}

function readBackups(owner, project) {
  try {
    return JSON.parse(runVestaCommand('v-list-docker-project-backups', [owner, project, 'json']));
  } catch {
    return [];
  }
}

async function openProjectActions(page) {
  await page.getByRole('link', { name: /Project actions/i }).click();
  const modal = page.locator('#floating-center-div-content').first();
  await expect(modal).toBeVisible();
  return modal;
}

async function closeProjectActions(page) {
  await page.keyboard.press('Escape');
  await expect(page.locator('#floating-center-div').first()).toBeHidden();
}

async function submitModalSelection(modal, field, value, button = /Continue/i) {
  await modal.locator(`select[name="${field}"]`).selectOption(String(value));
  await modal.getByRole('button', { name: button }).click();
}

async function assertSpawnedOutput(modal, heading) {
  await expect(modal).toContainText(heading);
  await expect(modal.locator('textarea')).toBeVisible();
}

test('advanced preview/deploy, service controls, recovery actions, and redaction work end to end', async ({ page }) => {
  test.setTimeout(600_000);
  page.setDefaultTimeout(15_000);
  test.skip(
    !(hasLocalVestaRuntime() || hasRemoteVestaRuntime()) || !isLocalPanelTarget(),
    'Advanced destructive coverage requires the configured panel and exact Vesta runtime target.'
  );

  const owner = getPanelCredentials('dockerUser').username;
  const project = `pw-ui-${Date.now().toString(36)}`;
  const canary = `pw-redaction-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  const initialDefinition = composeProjectDefinition();

  try {
    await page.goto(`/add/docker/project/?user=${encodeURIComponent(owner)}`);
    const addForm = page.locator('#compose-advanced-add-form');
    await expect(page.getByRole('heading', { name: /Add Compose project/i })).toBeVisible();
    await expect(addForm).toBeVisible();
    await addForm.locator('input[name="project"]').fill(project);
    await addForm.locator('select[name="profile"]').selectOption('standard');
    await addForm.locator('textarea[name="definition"]').fill(initialDefinition);
    await addForm.getByRole('button', { name: /Validate/i }).click();

    const addPreview = page.locator('#compose-validation-preview');
    await expect(addPreview).toBeVisible();
    await expect(addPreview).toContainText(/"services"/i);
    await expect(addPreview).toContainText(/"web"/i);
    await expect(addPreview).toContainText(/"worker"/i);
    expect(await addPreview.textContent()).not.toContain(canary);
    expect(readProject(owner, project)).toBeNull();

    const deployForm = page.locator('#compose-deploy-confirm-form');
    await expect(deployForm.locator('input[name="preview_token"]')).toHaveValue(/\S+/);
    await deployForm.getByRole('button', { name: /Deploy/i }).click();
    await expect(page.locator('#compose-spawn-output')).toBeVisible();
    await expect(page.locator('#compose-spawn-output textarea')).toBeVisible();
    await expect.poll(
      () => {
        const record = readProject(owner, project);
        return record ? `${record.STATE}:${record.REVISION}` : '';
      },
      { timeout: 120_000 }
    ).toBe('running:1');

    addComposeProjectSecret(owner, project, 'ui_canary', `${canary}\n`);
    const updatedDefinition = composeProjectDefinition({
      secretPath: managedSecretPath(owner, project, 'ui_canary'),
    });

    await page.goto(
      `/edit/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
    );
    const updateForm = page.locator('#compose-advanced-update-form');
    await expect(updateForm).toBeVisible();
    await updateForm.locator('textarea[name="definition"]').fill(updatedDefinition);
    await updateForm.getByRole('button', { name: /Validate/i }).click();

    const updatePreview = page.locator('#compose-update-validation-preview');
    await expect(updatePreview).toBeVisible();
    await expect(updatePreview).toContainText(/ui_canary/);
    expect(await updatePreview.textContent()).not.toContain(canary);
    const updateConfirm = page.locator('#compose-update-confirm-form');
    await expect(updateConfirm.locator('input[name="preview_token"]')).toHaveValue(/\S+/);
    await updateConfirm.getByRole('button', { name: /Update/i }).click();
    await expect(page.locator('#compose-spawn-output')).toBeVisible();
    await expect.poll(
      () => {
        const record = readProject(owner, project);
        return record ? `${record.STATE}:${record.REVISION}` : '';
      },
      { timeout: 120_000 }
    ).toBe('running:2');

    await page.goto(
      `/list/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
    );
    await expect(page.getByRole('heading', { name: project })).toBeVisible();
    expect(await page.locator('body').textContent()).not.toContain(canary);

    let modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /View project logs/i }).click();
    await submitModalSelection(modal, 'service', 'worker', /View logs/i);
    await expect(modal).toContainText(/Compose project logs/i);
    const logOutput = await modal.locator('textarea').inputValue();
    expect(logOutput).toContain('[REDACTED]');
    expect(logOutput).not.toContain(canary);
    expect(await modal.textContent()).not.toContain(canary);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Project summary/i }).click();
    await expect(modal).toContainText(/Redacted Compose project summary/i);
    expect(await modal.textContent()).not.toContain(canary);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Audit trail/i }).click();
    await expect(modal).toContainText(/Compose project audit trail/i);
    expect(await modal.textContent()).not.toContain(canary);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Secret metadata/i }).click();
    await expect(modal).toContainText(/values are never returned/i);
    await expect(modal).toContainText(/ui_canary/);
    expect(await modal.textContent()).not.toContain(canary);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Recreate service/i }).click();
    await submitModalSelection(modal, 'service', 'worker');
    await expect(modal).toContainText(/Recreate service worker/i);
    await modal.getByRole('button', { name: /^No$/i }).click();
    await expect(page.locator('#floating-center-div').first()).toBeHidden();

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Recreate service/i }).click();
    await submitModalSelection(modal, 'service', 'worker');
    await modal.getByRole('button', { name: /^Yes$/i }).click();
    await assertSpawnedOutput(modal, /Compose service recreate output/i);
    await expect.poll(
      () => readProject(owner, project)?.STATE || '',
      { timeout: 120_000 }
    ).toBe('running');
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Create backup/i }).click();
    await expect(modal).toContainText(/managed backup/i);
    await modal.getByRole('button', { name: /^No$/i }).click();
    await expect(page.locator('#floating-center-div').first()).toBeHidden();
    expect(readBackups(owner, project)).toHaveLength(0);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Create backup/i }).click();
    await modal.getByRole('button', { name: /^Yes$/i }).click();
    await assertSpawnedOutput(modal, /Compose backup output/i);
    await expect.poll(
      () => readBackups(owner, project).length,
      { timeout: 120_000 }
    ).toBe(1);
    const backup = readBackups(owner, project)[0].ARCHIVE;
    expect(backup).toMatch(/\.tar\.gz$/);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Rollback revision/i }).click();
    await submitModalSelection(modal, 'revision', 1);
    await expect(modal).toContainText(/Roll back project/i);
    await modal.getByRole('button', { name: /^No$/i }).click();
    await expect(page.locator('#floating-center-div').first()).toBeHidden();
    expect(readProject(owner, project).REVISION).toBe(2);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Rollback revision/i }).click();
    await submitModalSelection(modal, 'revision', 1);
    await modal.getByRole('button', { name: /^Yes$/i }).click();
    await assertSpawnedOutput(modal, /Compose rollback output/i);
    await expect.poll(
      () => readProject(owner, project)?.REVISION || 0,
      { timeout: 120_000 }
    ).toBe(1);
    await closeProjectActions(page);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Restore backup/i }).click();
    await submitModalSelection(modal, 'archive', backup);
    await expect(modal).toContainText(/Validate and apply backup/i);
    await modal.getByRole('button', { name: /^No$/i }).click();
    await expect(page.locator('#floating-center-div').first()).toBeHidden();
    expect(readProject(owner, project).REVISION).toBe(1);

    modal = await openProjectActions(page);
    await modal.getByRole('button', { name: /Restore backup/i }).click();
    await submitModalSelection(modal, 'archive', backup);
    await modal.getByRole('button', { name: /^Yes$/i }).click();
    await assertSpawnedOutput(modal, /Compose restore output/i);
    await expect.poll(
      () => readProject(owner, project)?.REVISION || 0,
      { timeout: 180_000 }
    ).toBe(2);
    expect(await modal.textContent()).not.toContain(canary);

    const token = await readSessionToken(page);
    const mismatchedOwnerResponse = await page.request.post('/ajax/docker/index.php', {
      form: {
        token,
        'dataset[owner]': getPanelCredentials('admin').username,
        'dataset[project]': project,
        'dataset[container_name]': project,
      },
    });
    expect(await mismatchedOwnerResponse.text()).toMatch(/do not have access/i);
  } finally {
    deleteContainer(owner, project);
  }
});
