const { randomBytes } = require('crypto');
const { test, expect } = require('@playwright/test');
const {
  getPanelCredentials,
  readSessionToken,
} = require('./helpers/panel-auth');
const {
  changeComposeProject,
  composeProjectDefinition,
  deleteContainer,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  readComposeProject,
  remoteVestaSshArgs,
  remoteVestaSshExecution,
  runVestaCommand,
} = require('./helpers/docker-runtime-fixtures');

function composeProjectName(label, now = Date.now(), entropy = randomBytes) {
  return `pw-${label}-${now.toString(36)}-${entropy(6).toString('hex')}`;
}

function requireDisposableRuntime() {
  test.skip(
    !(hasLocalVestaRuntime() || hasRemoteVestaRuntime()) || !isLocalPanelTarget(),
    'Compose self-service coverage requires the configured panel and exact disposable Vesta runtime target.'
  );
}

async function previewNewProject(page, owner, project, definition) {
  await page.goto(`/add/docker/project/?user=${encodeURIComponent(owner)}`);
  const form = page.locator('#compose-advanced-add-form');
  await expect(form).toBeVisible();
  await form.locator('input[name="project"]').fill(project);
  await form.locator('textarea[name="definition"]').fill(definition);
  await form.getByRole('button', { name: /Validate and preview/i }).click();
  const preview = page.locator('#compose-validation-preview');
  await expect(preview).toBeVisible();
  return preview;
}

async function previewProjectUpdate(page, owner, project, definition) {
  await page.goto(
    `/edit/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
  );
  const form = page.locator('#compose-advanced-update-form');
  await expect(form).toBeVisible();
  const source = form.locator('textarea[name="definition"]');
  await expect(source).not.toHaveValue('');
  await source.fill(definition);
  await form.getByRole('button', { name: /Validate and preview/i }).click();
  const preview = page.locator('#compose-update-validation-preview');
  await expect(preview).toBeVisible();
  return preview;
}

async function confirmationFields(form) {
  const controls = form.locator('input, textarea');
  const fields = {};
  for (let index = 0; index < await controls.count(); index += 1) {
    const control = controls.nth(index);
    const name = await control.getAttribute('name');
    if (name) {
      fields[name] = await control.inputValue();
    }
  }
  return fields;
}

async function waitForProject(owner, project, expected, timeout = 120_000) {
  await expect.poll(
    () => {
      const record = readComposeProject(owner, project);
      return record ? `${record.STATE}:${record.REVISION}` : '';
    },
    { timeout }
  ).toBe(expected);
}

function trackSpawnWatcher(page) {
  const responses = [];
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('response', (response) => {
    if (new URL(response.url()).pathname === '/ajax/watch-spawned-ajax-process.php') {
      responses.push(response.json().then(
        (body) => ({ body, status: response.status() }),
        () => ({ body: null, status: response.status() })
      ));
    }
  });
  return { pageErrors, responses };
}

async function expectWatcherActivitySince(tracker, responseCount) {
  await expect.poll(() => tracker.responses.length).toBeGreaterThan(responseCount);
  return Promise.all(tracker.responses.slice(responseCount));
}

async function expectTerminalWatcherSince(tracker, responseCount, timeout = 120_000) {
  await expect.poll(async () => {
    const responses = await Promise.all(tracker.responses.slice(responseCount));
    return responses.some(({ body, status }) =>
      status === 200 && body && Number(body.code) > 0
    );
  }, { timeout }).toBe(true);
}

test('Compose project reads fail closed and generated names are collision-resistant', () => {
  const project = 'pw-read-contract';
  const notFound = Object.assign(new Error('expected absence'), {
    status: 3,
    stderr: `Error: Compose project does not exist :: ${project}\n`,
  });
  expect(readComposeProject('owner', project, () => {
    throw notFound;
  })).toBeNull();

  for (const error of [
    Object.assign(new Error('transport failed'), { status: 255, stderr: 'ssh failed' }),
    Object.assign(new Error('wrong status'), {
      status: 3,
      stderr: `Error: Permission denied :: ${project}\n`,
    }),
  ]) {
    expect(() => readComposeProject('owner', project, () => {
      throw error;
    })).toThrow(error);
  }
  expect(() => readComposeProject('owner', project, () => '{not-json')).toThrow(SyntaxError);

  const names = Array.from(
    { length: 32 },
    () => composeProjectName('collision', 1_785_300_000_000)
  );
  expect(new Set(names).size).toBe(names.length);
  for (const name of names) {
    expect(name).toMatch(/^pw-collision-[a-z0-9]+-[a-f0-9]{12}$/);
    expect(name.length).toBeLessThanOrEqual(48);
  }
});

test('remote Vesta SSH jump arguments reject option injection and keep input off argv', () => {
  const priorTarget = process.env.PLAYWRIGHT_REMOTE_VESTA_SSH;
  const priorJump = process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP;
  const priorBaseUrl = process.env.PLAYWRIGHT_BASE_URL;
  const priorPanelRuntimeHost = process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST;
  const secret = 'playwright-secret-argv-canary';
  try {
    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH = 'operator@192.0.2.20';
    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP = 'builder@192.0.2.30';
    const args = remoteVestaSshArgs('exec sudo -n bash -se');
    expect(args).toEqual([
      '-J',
      'builder@192.0.2.30',
      'operator@192.0.2.20',
      'exec sudo -n bash -se',
    ]);
    process.env.PLAYWRIGHT_BASE_URL = 'https://127.0.0.1:18443';
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = '192.0.2.20';
    expect(isLocalPanelTarget()).toBe(true);
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = '192.168.100.101';
    expect(isLocalPanelTarget()).toBe(false);
    process.env.PLAYWRIGHT_BASE_URL = 'https://production.example.com:8083';
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = '192.0.2.20';
    expect(isLocalPanelTarget()).toBe(false);
    process.env.PLAYWRIGHT_BASE_URL = 'https://127.0.0.1:18443';
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = 'operator@192.0.2.20';
    expect(() => isLocalPanelTarget()).toThrow(/must not include a user name/);
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = '192.0.2.20 extra';
    expect(() => isLocalPanelTarget()).toThrow(/single SSH destination/);

    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = '192.0.2.20';
    const execution = remoteVestaSshExecution(`printf %s '${secret}'`);
    expect(execution.input).toContain(secret);
    expect(execution.args.join(' ')).not.toContain(secret);

    for (const invalid of [
      '-oProxyCommand=bad',
      'builder@host extra',
      'builder@host\n-oProxyCommand=bad',
    ]) {
      process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP = invalid;
      expect(() => remoteVestaSshArgs('exec sudo -n bash -se')).toThrow(
        /single SSH destination/
      );
    }

    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP = '';
    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH = 'debian@host -oProxyCommand=bad';
    expect(() => remoteVestaSshArgs('exec sudo -n bash -se')).toThrow(
      /single SSH destination/
    );
  } finally {
    if (priorTarget === undefined) {
      delete process.env.PLAYWRIGHT_REMOTE_VESTA_SSH;
    } else {
      process.env.PLAYWRIGHT_REMOTE_VESTA_SSH = priorTarget;
    }
    if (priorJump === undefined) {
      delete process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP;
    } else {
      process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP = priorJump;
    }
    if (priorBaseUrl === undefined) {
      delete process.env.PLAYWRIGHT_BASE_URL;
    } else {
      process.env.PLAYWRIGHT_BASE_URL = priorBaseUrl;
    }
    if (priorPanelRuntimeHost === undefined) {
      delete process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST;
    } else {
      process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST = priorPanelRuntimeHost;
    }
  }
});

test('owner self-service previews, deploys, updates, and rejects authority tampering', async ({ page }) => {
  test.setTimeout(420_000);
  requireDisposableRuntime();

  const owner = getPanelCredentials('dockerUser').username;
  const otherOwner = owner === 'admin' ? 'root' : 'admin';
  const project = composeProjectName('self');
  const watcher = trackSpawnWatcher(page);

  try {
    const initialDefinition = composeProjectDefinition();
    const addPreview = await previewNewProject(page, owner, project, initialDefinition);
    await expect(addPreview).toContainText(/web/i);
    await expect(addPreview).toContainText(/worker/i);
    expect(readComposeProject(owner, project)).toBeNull();

    const deployWatcherCount = watcher.responses.length;
    await page.locator('#compose-deploy-confirm-form')
      .getByRole('button', { name: /Confirm and deploy/i }).click();
    await expect(page.locator('#compose-spawn-output textarea')).toBeVisible();
    await expectWatcherActivitySince(watcher, deployWatcherCount);
    await waitForProject(owner, project, 'running:1');
    await expectTerminalWatcherSince(watcher, deployWatcherCount);

    await page.goto(`/list/docker/?user=${encodeURIComponent(owner)}`);
    await expect(page.getByRole('link', { name: 'Advanced Compose' })).toBeVisible();
    await page.goto(
      `/list/docker/project/?project=${encodeURIComponent(project)}&user=${encodeURIComponent(owner)}`
    );
    await expect(page.getByRole('link', { name: 'Advanced update' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Restart' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Project actions' })).toBeVisible();

    const updatePreview = await previewProjectUpdate(
      page,
      owner,
      project,
      composeProjectDefinition({ services: ['web'] })
    );
    await expect(updatePreview).toContainText(/Services removed/i);
    await expect(updatePreview).toContainText(/worker/i);

    const confirmForm = page.locator('#compose-update-confirm-form');
    const fields = await confirmationFields(confirmForm);
    const token = await readSessionToken(page);
    expect(fields.token).toBe(token);
    const beforeTampering = readComposeProject(owner, project);

    for (const tampering of [
      { owner: otherOwner },
      { profile: 'admin-approved' },
    ]) {
      const response = await page.request.post(page.url(), {
        form: {
          ...fields,
          ...tampering,
          token,
          confirm_update: '1',
        },
      });
      expect(await response.text()).toMatch(/expired or changed|validate it again/i);
      const afterTampering = readComposeProject(owner, project);
      expect(afterTampering.OWNER).toBe(beforeTampering.OWNER);
      expect(afterTampering.PROFILE).toBe(beforeTampering.PROFILE);
      expect(afterTampering.REVISION).toBe(beforeTampering.REVISION);
    }

    const updateWatcherCount = watcher.responses.length;
    await confirmForm.getByRole('button', { name: /Confirm update/i }).click();
    await expect(page.locator('#compose-spawn-output textarea')).toBeVisible();
    await expectWatcherActivitySince(watcher, updateWatcherCount);
    await waitForProject(owner, project, 'running:2');
    await expectTerminalWatcherSince(watcher, updateWatcherCount);
    expect(watcher.pageErrors).toEqual([]);
  } finally {
    deleteContainer(owner, project);
  }
});

test('stale self-service confirmation cannot overwrite a newer revision', async ({ page }) => {
  test.setTimeout(300_000);
  requireDisposableRuntime();

  const owner = getPanelCredentials('dockerUser').username;
  const project = composeProjectName('stale');
  const watcher = trackSpawnWatcher(page);

  try {
    await previewNewProject(
      page,
      owner,
      project,
      composeProjectDefinition({ services: ['web'] })
    );
    const deployWatcherCount = watcher.responses.length;
    await page.locator('#compose-deploy-confirm-form')
      .getByRole('button', { name: /Confirm and deploy/i }).click();
    await expectWatcherActivitySince(watcher, deployWatcherCount);
    await waitForProject(owner, project, 'running:1');
    await expectTerminalWatcherSince(watcher, deployWatcherCount);

    await previewProjectUpdate(
      page,
      owner,
      project,
      composeProjectDefinition({ services: ['worker'] })
    );
    const confirmForm = page.locator('#compose-update-confirm-form');
    const fields = await confirmationFields(confirmForm);

    changeComposeProject(owner, project, composeProjectDefinition());
    await waitForProject(owner, project, 'running:2');

    const response = await page.request.post(page.url(), {
      form: { ...fields, confirm_update: '1' },
    });
    expect(await response.text()).toMatch(/expired or changed|validate it again/i);
    await waitForProject(owner, project, 'running:2');
    expect(watcher.pageErrors).toEqual([]);
  } finally {
    deleteContainer(owner, project);
  }
});

test('failed unhealthy self-service update rolls back to the healthy revision', async ({ page }) => {
  test.setTimeout(420_000);
  requireDisposableRuntime();

  const owner = getPanelCredentials('dockerUser').username;
  const project = composeProjectName('rollback');
  const watcher = trackSpawnWatcher(page);

  try {
    await previewNewProject(
      page,
      owner,
      project,
      composeProjectDefinition({ services: ['web'] })
    );
    const deployWatcherCount = watcher.responses.length;
    await page.locator('#compose-deploy-confirm-form')
      .getByRole('button', { name: /Confirm and deploy/i }).click();
    await expectWatcherActivitySince(watcher, deployWatcherCount);
    await waitForProject(owner, project, 'running:1');
    await expectTerminalWatcherSince(watcher, deployWatcherCount);

    await previewProjectUpdate(
      page,
      owner,
      project,
      composeProjectDefinition({ services: ['web'], unhealthy: true })
    );
    const updateWatcherCount = watcher.responses.length;
    await page.locator('#compose-update-confirm-form')
      .getByRole('button', { name: /Confirm update/i }).click();
    const output = page.locator('#compose-spawn-output textarea');
    await expect(output).toBeVisible();
    await expectWatcherActivitySince(watcher, updateWatcherCount);
    await expect(output).toHaveValue(/failed/i, { timeout: 120_000 });
    await expect.poll(async () => {
      const responses = await Promise.all(watcher.responses.slice(updateWatcherCount));
      return responses.some(({ body, status }) =>
        status === 200
        && body
        && Number(body.code) > 0
        && (Number(body.exit_code) !== 0 || /failed/i.test(body.output || ''))
      );
    }, { timeout: 120_000 }).toBe(true);
    await waitForProject(owner, project, 'running:1', 120_000);

    const audit = JSON.parse(
      runVestaCommand('v-list-docker-project-audit', [owner, project, 'json'])
    );
    expect(audit).toEqual(expect.arrayContaining([
      expect.objectContaining({
        ACTION: 'transaction-update',
        RESULT: 'failed',
        DETAILS: expect.stringContaining('prior runtime restored'),
      }),
    ]));
    expect(watcher.pageErrors).toEqual([]);
  } finally {
    deleteContainer(owner, project);
  }
});
