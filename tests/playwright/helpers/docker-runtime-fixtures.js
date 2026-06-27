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

function getRemoteVestaSshTarget() {
  return (process.env.PLAYWRIGHT_REMOTE_VESTA_SSH || '').trim();
}

function hasRemoteVestaRuntime() {
  return getRemoteVestaSshTarget() !== '';
}

function hasExplicitLocalRuntimeTarget() {
  return (process.env.PLAYWRIGHT_LOCAL_RUNTIME_TARGET || '').trim().toLowerCase() === 'yes';
}

function isLocalPanelTarget() {
  const baseUrl = process.env.PLAYWRIGHT_BASE_URL || 'https://192.168.100.100:8083';
  const hostname = new URL(baseUrl).hostname;

  if (hasRemoteVestaRuntime()) {
    const remoteTarget = getRemoteVestaSshTarget();
    const remoteHost = remoteTarget.includes('@') ? remoteTarget.split('@').pop() : remoteTarget;
    return remoteHost === hostname;
  }

  if (!hasLocalVestaRuntime() || !hasExplicitLocalRuntimeTarget()) {
    return false;
  }

  const localHosts = new Set(['localhost', '127.0.0.1', '::1', os.hostname()]);

  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses || []) {
      if (address && address.address) {
        localHosts.add(address.address);
      }
    }
  }

  try {
    const resolvedHosts = execFileSync('getent', ['hosts', hostname], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim().split('\n');
    for (const entry of resolvedHosts) {
      const ip = entry.trim().split(/\s+/)[0];
      if (ip && localHosts.has(ip)) {
        return true;
      }
    }
  } catch {
    // Best-effort only; unresolved aliases simply fall back to the direct checks above.
  }

  return localHosts.has(hostname);
}

let cachedVestaRoot = null;

function runRemoteBash(script) {
  const remoteCommand = 'if [ "$(id -u)" -eq 0 ]; then exec bash -se; fi; if command -v sudo >/dev/null 2>&1; then exec sudo -n bash -se; fi; echo "Remote Vesta runtime access requires root or passwordless sudo." >&2; exit 1';

  return execFileSync('ssh', [getRemoteVestaSshTarget(), remoteCommand], {
    encoding: 'utf8',
    input: script,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function getVestaRoot() {
  if (cachedVestaRoot !== null) {
    return cachedVestaRoot;
  }

  if (hasRemoteVestaRuntime()) {
    cachedVestaRoot = runRemoteBash('source /etc/profile.d/vesta.sh && printf %s "$VESTA"').trim();
    if (!cachedVestaRoot) {
      throw new Error('Unable to resolve remote $VESTA from /etc/profile.d/vesta.sh.');
    }
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
  const cmd = `source /etc/profile.d/vesta.sh && "$VESTA/bin/${command}" ${args.map(shellEscape).join(' ')}`.trim();

  if (hasRemoteVestaRuntime()) {
    return runRemoteBash(cmd);
  }

  return execFileSync('bash', ['-lc', cmd], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function createDockerSpec(containerName, image) {
  const specDir = fs.mkdtempSync(path.join(os.tmpdir(), 'playwright-docker-'));
  const specPath = path.join(specDir, `${containerName}.spec`);
  fs.writeFileSync(specPath, `NAME='${containerName}'
IMAGE='${image || 'busybox:1.36.1'}'
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
  if (hasRemoteVestaRuntime()) {
    const specContent = `NAME='${containerName}'
IMAGE='${image || 'busybox:1.36.1'}'
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
`;
    const script = [
      'set -euo pipefail',
      'source /etc/profile.d/vesta.sh',
      'spec_dir="$(mktemp -d)"',
      `cat > "$spec_dir/${containerName}.spec" <<'EOF_SPEC'`,
      specContent.trimEnd(),
      'EOF_SPEC',
      `"$VESTA/bin/v-add-docker-container" ${shellEscape(owner)} "$spec_dir/${containerName}.spec"`,
      'rm -rf "$spec_dir"',
    ].join('\n');
    runRemoteBash(script);
    return;
  }

  const { specDir, specPath } = createDockerSpec(containerName, image);
  try {
    runVestaCommand('v-add-docker-container', [owner, specPath]);
  } finally {
    fs.rmSync(specDir, { recursive: true, force: true });
  }
}

function listContainers(owner) {
  const output = runVestaCommand('v-list-docker-containers', [owner, 'json']);
  const parsed = JSON.parse(output || '{}');

  return Object.values(parsed).map((record) => ({
    ctnName: record.CTN_NAME || '',
    name: record.NAME || '',
  }));
}

function cleanupContainersWithPrefix(owner, prefix = 'pw-') {
  for (const container of listContainers(owner)) {
    if (container.name && container.name.startsWith(prefix)) {
      deleteContainer(owner, container.name);
    }
  }
}

function deleteContainer(owner, containerName) {
  try {
    runVestaCommand('v-list-docker-container', [owner, containerName, 'json']);
  } catch (error) {
    if (error && error.status === 3) {
      return false;
    }

    throw error;
  }

  runVestaCommand('v-delete-docker-container', [owner, containerName]);
  return true;
}

function withSeededAlert(owner, containerName) {
  const seededAid = `9${Date.now()}`;
  const seededTitle = `Playwright alert ${seededAid}`;
  const seededLine = `AID='${seededAid}' NAME='${containerName}' OWNER='${owner}' LEVEL='warning' TYPE='manual' STATUS='open' TITLE='${seededTitle}' MESSAGE='Seeded alert for Playwright coverage' STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'`;

  if (hasRemoteVestaRuntime()) {
    const alertsPath = `${getVestaRoot()}/data/users/${owner}/docker-alerts.conf`;
    const seedScript = [
      'set -euo pipefail',
      `alerts_path=${shellEscape(alertsPath)}`,
      `seeded_line=${shellEscape(seededLine)}`,
      'existing=""',
      '[ -f "$alerts_path" ] && existing="$(sed -e \'$a\\\' "$alerts_path")"',
      'if [ -n "$existing" ]; then',
      '  printf "%s\\n%s" "$seeded_line" "$existing" > "$alerts_path"',
      'else',
      '  printf "%s\\n" "$seeded_line" > "$alerts_path"',
      'fi',
    ].join('\n');
    runRemoteBash(seedScript);

    return {
      seededAid,
      seededTitle,
      restore() {
        const restoreScript = [
          'set -euo pipefail',
          `alerts_path=${shellEscape(alertsPath)}`,
          `seeded_aid=${shellEscape(seededAid)}`,
          '[ -f "$alerts_path" ] || exit 0',
          'filtered="$(grep -v "AID=\'$seeded_aid\'" "$alerts_path" || true)"',
          'if [ -n "$filtered" ]; then',
          '  printf "%s\\n" "$filtered" > "$alerts_path"',
          'else',
          '  rm -f "$alerts_path"',
          'fi',
        ].join('\n');
        runRemoteBash(restoreScript);
      },
    };
  }

  const alertsPath = path.join(getVestaRoot(), 'data', 'users', owner, 'docker-alerts.conf');
  const existing = fs.existsSync(alertsPath) ? fs.readFileSync(alertsPath, 'utf8').trimEnd() : '';
  const nextContent = existing ? `${seededLine}\n${existing}\n` : `${seededLine}\n`;
  fs.writeFileSync(alertsPath, nextContent);

  return {
    seededAid,
    seededTitle,
    restore() {
    if (!fs.existsSync(alertsPath)) {
      return;
    }

    const filtered = fs.readFileSync(alertsPath, 'utf8')
      .split('\n')
      .filter((line) => line && !line.includes(`AID='${seededAid}'`))
      .join('\n');

    if (filtered) {
      fs.writeFileSync(alertsPath, `${filtered}\n`);
    } else {
      fs.rmSync(alertsPath, { force: true });
    }
    },
  };
}

module.exports = {
  cleanupContainersWithPrefix,
  createDisposableContainer,
  deleteContainer,
  hasExplicitLocalRuntimeTarget,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  withSeededAlert,
};
