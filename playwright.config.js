const path = require('path');
const { defineConfig, devices } = require('@playwright/test');

require('dotenv').config({
  path: process.env.PLAYWRIGHT_ENV_FILE || '.env.playwright',
});

const authDir = path.join(__dirname, 'playwright', '.auth');
const adminAuthStatePath = path.join(authDir, 'admin.json');
const dockerUserAuthStatePath = path.join(authDir, 'docker-user.json');
const hasAdminCredentials = Boolean(
  process.env.PLAYWRIGHT_ADMIN_USER && process.env.PLAYWRIGHT_ADMIN_PASSWORD
);
const hasDockerUserCredentials = Boolean(
  process.env.PLAYWRIGHT_DOCKER_USER && process.env.PLAYWRIGHT_DOCKER_PASSWORD
);

const projects = [
  {
    name: 'setup',
    testMatch: /.*\.setup\.js/,
  },
  {
    name: 'chromium-anonymous',
    use: {
      ...devices['Desktop Chrome'],
    },
    testIgnore: [/.*\.setup\.js/, /.*\.authenticated\.spec\.js/],
  },
];

if (hasAdminCredentials) {
  projects.push({
    name: 'chromium-admin-authenticated',
    dependencies: ['setup'],
    use: {
      ...devices['Desktop Chrome'],
      storageState: adminAuthStatePath,
    },
    testIgnore: [
      /.*\.setup\.js/,
      /.*\.anonymous\.spec\.js/,
      /.*\.user\.authenticated\.spec\.js/,
    ],
  });
}

if (hasDockerUserCredentials) {
  projects.push({
    name: 'chromium-docker-user-authenticated',
    dependencies: ['setup'],
    use: {
      ...devices['Desktop Chrome'],
      storageState: dockerUserAuthStatePath,
    },
    testIgnore: [
      /.*\.setup\.js/,
      /.*\.anonymous\.spec\.js/,
      /.*\.admin\.authenticated\.spec\.js/,
    ],
  });
}

module.exports = defineConfig({
  testDir: path.join(__dirname, 'tests', 'playwright'),
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
  ],
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'https://192.168.100.100:8083',
    ignoreHTTPSErrors: true,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects,
});
