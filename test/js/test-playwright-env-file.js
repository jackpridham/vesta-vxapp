const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  DEFAULT_ENV_FILENAME,
  loadPlaywrightEnv,
} = require('../../tests/playwright/helpers/env-file');

const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vx-playwright-env-'));

function expectFailure(messagePattern, callback) {
  assert.throws(callback, messagePattern);
}

try {
  const emptyEnv = {};
  assert.strictEqual(loadPlaywrightEnv({ cwd: testRoot, env: emptyEnv }), null);

  expectFailure(/does not exist/, () => loadPlaywrightEnv({
    cwd: testRoot,
    env: { PLAYWRIGHT_ENV_FILE: 'missing.env' },
  }));

  const securePath = path.join(testRoot, DEFAULT_ENV_FILENAME);
  fs.writeFileSync(securePath, 'PLAYWRIGHT_ADMIN_PASSWORD=test-only-value\n', { mode: 0o600 });
  const loadedEnv = {};
  assert.strictEqual(loadPlaywrightEnv({ cwd: testRoot, env: loadedEnv }), securePath);
  assert.strictEqual(loadedEnv.PLAYWRIGHT_ADMIN_PASSWORD, 'test-only-value');

  fs.chmodSync(securePath, 0o640);
  expectFailure(/mode must be 0600/, () => loadPlaywrightEnv({ cwd: testRoot, env: {} }));
  fs.chmodSync(securePath, 0o600);

  expectFailure(/owned by the current user/, () => loadPlaywrightEnv({
    cwd: testRoot,
    env: {},
    expectedUid: fs.statSync(securePath).uid + 1,
  }));

  const directoryPath = path.join(testRoot, 'directory.env');
  fs.mkdirSync(directoryPath);
  expectFailure(/regular file/, () => loadPlaywrightEnv({
    cwd: testRoot,
    env: { PLAYWRIGHT_ENV_FILE: directoryPath },
  }));

  const symlinkPath = path.join(testRoot, 'symlink.env');
  fs.symlinkSync(securePath, symlinkPath);
  expectFailure(/must not be a symlink/, () => loadPlaywrightEnv({
    cwd: testRoot,
    env: { PLAYWRIGHT_ENV_FILE: symlinkPath },
  }));

  const preservedEnv = {
    PLAYWRIGHT_ENV_FILE: securePath,
    PLAYWRIGHT_ADMIN_PASSWORD: 'already-set',
  };
  loadPlaywrightEnv({ cwd: testRoot, env: preservedEnv });
  assert.strictEqual(preservedEnv.PLAYWRIGHT_ADMIN_PASSWORD, 'already-set');
} finally {
  fs.rmSync(testRoot, { recursive: true, force: true });
}

console.log('Playwright environment-file tests passed.');
