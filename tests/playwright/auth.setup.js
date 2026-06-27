const { test: setup } = require('@playwright/test');
const {
  ensureAuthStateDir,
  getAuthStatePath,
  getPanelCredentials,
  hasPanelCredentials,
  loginWithPassword,
} = require('./helpers/panel-auth');

setup('create authenticated storage states for configured panel roles', async ({ browser, baseURL }) => {
  ensureAuthStateDir();

  const roles = ['admin', 'dockerUser'];
  let createdStates = 0;

  for (const role of roles) {
    if (!hasPanelCredentials(role)) {
      continue;
    }

    const context = await browser.newContext({
      baseURL,
      ignoreHTTPSErrors: true,
    });
    const page = await context.newPage();

    await loginWithPassword(page, getPanelCredentials(role));
    await context.storageState({
      path: getAuthStatePath(role),
    });

    await context.close();
    createdStates += 1;
  }

  if (createdStates === 0) {
    console.warn('No authenticated Playwright storage states were created because no panel credentials were configured.');
  }
});
