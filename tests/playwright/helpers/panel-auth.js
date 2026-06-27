const path = require('path');
const fs = require('fs');

require('dotenv').config({
  path: process.env.PLAYWRIGHT_ENV_FILE || path.resolve(process.cwd(), '.env.playwright'),
});

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required Playwright environment variable: ${name}`);
  }
  return value;
}

function hasEnv(name) {
  return Boolean(process.env[name]);
}

function getOptionalEnv(name, defaultValue = '') {
  return Object.prototype.hasOwnProperty.call(process.env, name) ? process.env[name] : defaultValue;
}

function hasPanelCredentials(role = 'admin') {
  if (role === 'admin') {
    return hasEnv('PLAYWRIGHT_ADMIN_USER') && hasEnv('PLAYWRIGHT_ADMIN_PASSWORD');
  }

  if (role === 'dockerUser') {
    return hasEnv('PLAYWRIGHT_DOCKER_USER') && hasEnv('PLAYWRIGHT_DOCKER_PASSWORD');
  }

  throw new Error(`Unknown Playwright panel role: ${role}`);
}

function getPanelCredentials(role = 'admin') {
  if (role === 'admin') {
    return {
      username: requireEnv('PLAYWRIGHT_ADMIN_USER'),
      password: requireEnv('PLAYWRIGHT_ADMIN_PASSWORD'),
    };
  }

  if (role === 'dockerUser') {
    return {
      username: requireEnv('PLAYWRIGHT_DOCKER_USER'),
      password: requireEnv('PLAYWRIGHT_DOCKER_PASSWORD'),
    };
  }

  throw new Error(`Unknown Playwright panel role: ${role}`);
}

function getAuthStatePath(role = 'admin') {
  const authDir = path.resolve(process.cwd(), 'playwright', '.auth');
  const filename = role === 'dockerUser' ? 'docker-user.json' : 'admin.json';
  return path.join(authDir, filename);
}

async function openPanelLogin(page) {
  const loginSecret = process.env.PLAYWRIGHT_LOGIN_SECRET;

  if (loginSecret) {
    await page.goto(`/?${encodeURIComponent(loginSecret)}`);
    await page.waitForURL(/\/login\/?$/, {
      timeout: 15_000,
    });
  }

  await page.goto('/login/');
}

async function loginWithPassword(page, { username, password }) {
  await openPanelLogin(page);
  await page.locator('input[name="token"]').waitFor();

  await page.fill('input[name="user"]', username);
  await page.fill('input[name="password"]', password);
  await page.getByRole('button', { name: /log in/i }).click();

  await page.waitForURL(/\/list\/user\/|\/list\/web\/|\/list\/docker\/|\/login\/\?loginas=/, {
    timeout: 15_000,
  });
}

async function loginAsRole(page, role = 'admin') {
  await loginWithPassword(page, getPanelCredentials(role));
}

async function readSessionToken(page) {
  const tokenLocator = page.locator('#token');
  await tokenLocator.waitFor();
  return tokenLocator.getAttribute('token');
}

async function switchLookUser(page, username) {
  const token = await readSessionToken(page);
  if (!token) {
    throw new Error('Unable to read session token from the panel');
  }

  await page.goto(`/login/?loginas=${encodeURIComponent(username)}&token=${encodeURIComponent(token)}`);
  await page.waitForLoadState('networkidle');
}

function ensureAuthStateDir() {
  const authDir = path.resolve(process.cwd(), 'playwright', '.auth');
  fs.mkdirSync(authDir, { recursive: true });
  return authDir;
}

module.exports = {
  ensureAuthStateDir,
  getAuthStatePath,
  getPanelCredentials,
  getOptionalEnv,
  hasPanelCredentials,
  loginAsRole,
  loginWithPassword,
  openPanelLogin,
  readSessionToken,
  switchLookUser,
};
