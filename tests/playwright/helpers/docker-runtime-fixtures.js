const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function hasLocalVestaRuntime() {
  return fs.existsSync('/etc/profile.d/vesta.sh');
}

let cachedVestaRoot = null;

function getVestaRoot() {
  if (cachedVestaRoot !== null) {
    return cachedVestaRoot;
  }

  if (!hasLocalVestaRuntime()) {
    throw new Error('Local Vesta runtime is unavailable.');
  }

  cachedVestaRoot = execFileSync('bash', ['-lc', 'source /etc/profile.d/vesta.sh && printf %s "$VESTA"'], {
    encoding: 'utf8',
  }).trim();

  if (!cachedVestaRoot) {
    throw new Error('Unable to resolve $VESTA from /etc/profile.d/vesta.sh.');
  }

  return cachedVestaRoot;
}

function runVestaCommand(command, args = []) {
  const cmd = [
    'source /etc/profile.d/vesta.sh',
    `"$VESTA/bin/${command}"`,
    ...args.map(shellEscape),
  ].join(' ');

  return execFileSync('bash', ['-lc', cmd], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function createDockerSpec(containerName, image) {
  const specDir = fs.mkdtempSync(path.join(os.tmpdir(), 'playwright-docker-'));
  const specPath = path.join(specDir, `${containerName}.spec`);
  fs.writeFileSync(specPath, `NAME='${containerName}'
IMAGE='${image}'
COMMAND='sleep 3600'
ENV='MODE=playwright'
MOUNTS='data:/data'
CONTAINER_PORT='8080'
DOMAIN=''
ROUTE_PATH=''
AUTO_START='no'
RESTART_POLICY='unless-stopped'
HEALTHCHECK_TYPE='none'
HEALTHCHECK_TARGET=''
HEALTHCHECK_INTERVAL='60'
CPU_ALERT_PCT='85'
MEM_ALERT_MB='1024'
NET_ALERT_MBPS='50'
ALERT_EMAIL='yes'
`);
  return { specDir, specPath };
}

function createDisposableContainer(owner, containerName, image) {
  const { specDir, specPath } = createDockerSpec(containerName, image);
  try {
    runVestaCommand('v-add-docker-container', [owner, specPath]);
  } finally {
    fs.rmSync(specDir, { recursive: true, force: true });
  }
}

function deleteContainer(owner, containerName) {
  try {
    runVestaCommand('v-list-docker-container', [owner, containerName, 'json']);
  } catch (error) {
    return false;
  }

  runVestaCommand('v-delete-docker-container', [owner, containerName]);
  return true;
}

function withSeededAlert(owner, containerName) {
  const alertsPath = path.join(getVestaRoot(), 'data', 'users', owner, 'docker-alerts.conf');
  const seededLine = `AID='9${Date.now()}' NAME='${containerName}' OWNER='${owner}' LEVEL='warning' TYPE='health' STATUS='open' TITLE='Playwright alert' MESSAGE='Seeded alert for Playwright coverage' STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'`;
  const existing = fs.existsSync(alertsPath) ? fs.readFileSync(alertsPath, 'utf8').trimEnd() : '';
  const nextContent = existing ? `${existing}\n${seededLine}\n` : `${seededLine}\n`;
  fs.writeFileSync(alertsPath, nextContent);

  return () => {
    if (!fs.existsSync(alertsPath)) {
      return;
    }

    const filtered = fs.readFileSync(alertsPath, 'utf8')
      .split('\n')
      .filter((line) => line && line !== seededLine)
      .join('\n');

    if (filtered) {
      fs.writeFileSync(alertsPath, `${filtered}\n`);
    } else {
      fs.rmSync(alertsPath, { force: true });
    }
  };
}

module.exports = {
  createDisposableContainer,
  deleteContainer,
  hasLocalVestaRuntime,
  withSeededAlert,
};
