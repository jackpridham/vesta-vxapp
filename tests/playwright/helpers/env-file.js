const fs = require('fs');
const path = require('path');
const dotenv = require('dotenv');

const DEFAULT_ENV_FILENAME = '.env.playwright.local';

function loadPlaywrightEnv({
  cwd = process.cwd(),
  env = process.env,
  expectedUid = typeof process.getuid === 'function' ? process.getuid() : null,
} = {}) {
  const selectedPath = env.PLAYWRIGHT_ENV_FILE || '';
  const explicit = selectedPath !== '';
  const envPath = path.resolve(cwd, explicit ? selectedPath : DEFAULT_ENV_FILENAME);

  let linkStat;
  try {
    linkStat = fs.lstatSync(envPath);
  } catch (error) {
    if (error && error.code === 'ENOENT' && !explicit) {
      return null;
    }
    if (error && error.code === 'ENOENT') {
      throw new Error(`Explicit Playwright environment file does not exist: ${envPath}`);
    }
    throw error;
  }

  if (linkStat.isSymbolicLink()) {
    throw new Error(`Playwright environment file must not be a symlink: ${envPath}`);
  }
  if (!linkStat.isFile()) {
    throw new Error(`Playwright environment file must be a regular file: ${envPath}`);
  }
  if (expectedUid === null) {
    throw new Error('Playwright environment file ownership cannot be verified on this platform');
  }
  if (linkStat.uid !== expectedUid) {
    throw new Error(`Playwright environment file must be owned by the current user: ${envPath}`);
  }
  if ((linkStat.mode & 0o777) !== 0o600) {
    throw new Error(`Playwright environment file mode must be 0600: ${envPath}`);
  }

  const noFollow = fs.constants.O_NOFOLLOW || 0;
  const closeOnExec = fs.constants.O_CLOEXEC || 0;
  const fd = fs.openSync(envPath, fs.constants.O_RDONLY | noFollow | closeOnExec);
  try {
    const fileStat = fs.fstatSync(fd);
    if (!fileStat.isFile() || fileStat.uid !== expectedUid || (fileStat.mode & 0o777) !== 0o600) {
      throw new Error(`Playwright environment file changed during validation: ${envPath}`);
    }

    const values = dotenv.parse(fs.readFileSync(fd, { encoding: 'utf8' }));
    for (const [name, value] of Object.entries(values)) {
      if (!Object.prototype.hasOwnProperty.call(env, name)) {
        env[name] = value;
      }
    }
  } finally {
    fs.closeSync(fd);
  }

  return envPath;
}

module.exports = {
  DEFAULT_ENV_FILENAME,
  loadPlaywrightEnv,
};
