const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const REMOTE_VESTA_COMMAND_TIMEOUT_MS = 180_000;

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function hasLocalVestaRuntime() {
  return fs.existsSync('/etc/profile.d/vesta.sh');
}

function sshDestination(value, variable) {
  if (value === '') {
    return '';
  }
  if (!/^(?:[A-Za-z0-9][A-Za-z0-9._-]*@)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\])$/.test(value)) {
    throw new Error(`${variable} must be a single SSH destination without options or whitespace.`);
  }
  return value;
}

function getRemoteVestaSshTarget() {
  return sshDestination(
    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH || '',
    'PLAYWRIGHT_REMOTE_VESTA_SSH'
  );
}

function getRemoteVestaSshJump() {
  return sshDestination(
    process.env.PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP || '',
    'PLAYWRIGHT_REMOTE_VESTA_SSH_JUMP'
  );
}

function getPanelRuntimeHost() {
  const host = sshDestination(
    process.env.PLAYWRIGHT_PANEL_RUNTIME_HOST || '',
    'PLAYWRIGHT_PANEL_RUNTIME_HOST'
  );
  if (host.includes('@')) {
    throw new Error('PLAYWRIGHT_PANEL_RUNTIME_HOST must not include a user name.');
  }
  return host;
}

function remoteVestaSshArgs(remoteCommand) {
  const target = getRemoteVestaSshTarget();
  const jump = getRemoteVestaSshJump();
  return jump
    ? ['-J', jump, target, remoteCommand]
    : [target, remoteCommand];
}

function remoteVestaSshExecution(script) {
  const remoteCommand = 'if [ "$(id -u)" -eq 0 ]; then exec bash -se; fi; if command -v sudo >/dev/null 2>&1; then exec sudo -n bash -se; fi; echo "Remote Vesta runtime access requires root or passwordless sudo." >&2; exit 1';
  return {
    args: remoteVestaSshArgs(remoteCommand),
    input: script,
  };
}

function hasRemoteVestaRuntime() {
  return getRemoteVestaSshTarget() !== '';
}

function hasExplicitLocalRuntimeTarget() {
  return (process.env.PLAYWRIGHT_LOCAL_RUNTIME_TARGET || '').trim().toLowerCase() === 'yes';
}

function isLocalPanelTarget() {
  const baseUrl = process.env.PLAYWRIGHT_BASE_URL || 'https://192.0.2.20:8083';
  const hostname = new URL(baseUrl).hostname;

  if (hasRemoteVestaRuntime()) {
    const remoteTarget = getRemoteVestaSshTarget();
    const remoteHost = remoteTarget.includes('@') ? remoteTarget.split('@').pop() : remoteTarget;
    const assertedPanelHost = getPanelRuntimeHost();
    if (assertedPanelHost !== '') {
      const loopbackHosts = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);
      return loopbackHosts.has(hostname) && remoteHost === assertedPanelHost;
    }
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
  const execution = remoteVestaSshExecution(script);

  return execFileSync('ssh', execution.args, {
    encoding: 'utf8',
    input: execution.input,
    stdio: ['pipe', 'pipe', 'pipe'],
    timeout: REMOTE_VESTA_COMMAND_TIMEOUT_MS,
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

function removeComposeServiceRuntime(owner, project, service) {
  for (const [name, value] of Object.entries({ owner, project, service })) {
    if (!/^[a-z][a-z0-9-]{0,62}$/.test(value)) {
      throw new Error(`Unsafe ${name} for scoped Compose runtime removal.`);
    }
  }

  const script = [
    'set -euo pipefail',
    `owner=${shellEscape(owner)}`,
    `project=${shellEscape(project)}`,
    `service=${shellEscape(service)}`,
    'mapfile -t ids < <(docker ps -aq \\',
    '  --filter "label=vx.user=$owner" \\',
    '  --filter "label=vx.project=$project" \\',
    '  --filter "label=com.docker.compose.service=$service")',
    '[[ "${#ids[@]}" -eq 1 ]]',
    'docker inspect "${ids[0]}" | jq -e \\',
    '  --arg owner "$owner" --arg project "$project" --arg service "$service" \\',
    '  \'.[0].Config.Labels["vx.user"] == $owner',
    '   and .[0].Config.Labels["vx.project"] == $project',
    '   and .[0].Config.Labels["com.docker.compose.service"] == $service\' >/dev/null',
    'docker rm -f -- "${ids[0]}" >/dev/null',
  ].join('\n');

  if (hasRemoteVestaRuntime()) {
    runRemoteBash(script);
    return;
  }
  if (!hasLocalVestaRuntime()) {
    throw new Error('A Vesta runtime is required for scoped container removal.');
  }
  execFileSync('bash', ['-se'], {
    encoding: 'utf8',
    input: script,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function composeProjectDefinition({
  image = 'busybox:1.36.1',
  secretPath = '',
  services = ['web', 'worker'],
  unhealthy = false,
} = {}) {
  const serviceBlocks = services.map((service) => {
    const readsSecret = service === 'worker' && secretPath;
    const command = readsSecret
      ? 'cat /run/s*/ui_canary; exec sleep 3600'
      : `printf '${service}-ready\\\\n'; exec sleep 3600`;
    const secretMount = readsSecret
      ? `
    secrets:
      - source: ui_canary
        target: /run/secrets/ui_canary
        mode: 0444`
      : '';
    const healthcheck = unhealthy
      ? `
    healthcheck:
      test:
        - CMD
        - "false"
      interval: 2s
      timeout: 1s
      retries: 2
      start_period: 1s`
      : '';

    return `  ${service}:
    image: ${image}
    command:
      - sh
      - -c
      - ${command}
    restart: unless-stopped
    init: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    cpus: 0.125
    mem_limit: 64m
    pids_limit: 32
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"${secretMount}${healthcheck}`;
  });
  const secretDefinition = secretPath
    ? `
secrets:
  ui_canary:
    file: ${secretPath}`
    : '';

  return `services:
${serviceBlocks.join('\n')}${secretDefinition}
`;
}

function isComposeProjectNotFound(error, project) {
  if (!error || error.status !== 3) {
    return false;
  }

  const expected = `Error: Compose project does not exist :: ${project}`;
  return [error.stdout, error.stderr].some((stream) => {
    const text = Buffer.isBuffer(stream) ? stream.toString('utf8') : String(stream || '');
    return text.split(/\r?\n/).some((line) => line.trim() === expected);
  });
}

function readComposeProject(owner, project, commandRunner = runVestaCommand) {
  let output;
  try {
    output = commandRunner('v-list-docker-project', [owner, project, 'json']);
  } catch (error) {
    if (isComposeProjectNotFound(error, project)) {
      return null;
    }
    throw error;
  }
  return JSON.parse(output);
}

function changeComposeProject(owner, project, definition) {
  if (!hasRemoteVestaRuntime()) {
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'playwright-compose-change-'));
    const fixtureFile = path.join(fixtureDir, 'compose.yaml');
    try {
      fs.writeFileSync(fixtureFile, definition, { mode: 0o600 });
      runVestaCommand('v-change-docker-project', [owner, project, fixtureFile]);
    } finally {
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
    return;
  }

  const encoded = Buffer.from(definition, 'utf8').toString('base64');
  const script = [
    'set -euo pipefail',
    'source /etc/profile.d/vesta.sh',
    'fixture_dir="$(mktemp -d)"',
    'fixture_file="$fixture_dir/compose.yaml"',
    'cleanup() { rm -rf -- "$fixture_dir"; }',
    'trap cleanup EXIT',
    `printf %s ${shellEscape(encoded)} | base64 -d > "$fixture_file"`,
    'chmod 0600 "$fixture_file"',
    `"$VESTA/bin/v-change-docker-project" ${shellEscape(owner)} ${shellEscape(project)} "$fixture_file"`,
  ].join('\n');
  runRemoteBash(script);
}

function createComposeProject(owner, project, definition, { deploy = true } = {}) {
  if (!hasRemoteVestaRuntime()) {
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'playwright-compose-'));
    const fixtureFile = path.join(fixtureDir, 'compose.yaml');
    try {
      fs.writeFileSync(fixtureFile, definition, { mode: 0o600 });
      runVestaCommand('v-add-docker-project', [owner, project, fixtureFile, 'standard']);
      if (deploy) {
        runVestaCommand('v-deploy-docker-project', [owner, project]);
      }
    } finally {
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
    return;
  }

  const encoded = Buffer.from(definition, 'utf8').toString('base64');
  const script = [
    'set -euo pipefail',
    'source /etc/profile.d/vesta.sh',
    'fixture_dir="$(mktemp -d)"',
    'fixture_file="$fixture_dir/compose.yaml"',
    'cleanup() { rm -rf -- "$fixture_dir"; }',
    'trap cleanup EXIT',
    `printf %s ${shellEscape(encoded)} | base64 -d > "$fixture_file"`,
    'chmod 0600 "$fixture_file"',
    `"$VESTA/bin/v-add-docker-project" ${shellEscape(owner)} ${shellEscape(project)} "$fixture_file" standard`,
  ];
  if (deploy) {
    script.push(`"$VESTA/bin/v-deploy-docker-project" ${shellEscape(owner)} ${shellEscape(project)}`);
  }
  runRemoteBash(script.join('\n'));
}

function addComposeProjectSecret(owner, project, name, value) {
  if (!hasRemoteVestaRuntime()) {
    const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'playwright-secret-'));
    const fixtureFile = path.join(fixtureDir, 'value');
    try {
      fs.writeFileSync(fixtureFile, value, { mode: 0o600 });
      runVestaCommand('v-add-docker-secret', [owner, project, name, fixtureFile]);
    } finally {
      fs.rmSync(fixtureDir, { recursive: true, force: true });
    }
    return;
  }

  const encoded = Buffer.from(value, 'utf8').toString('base64');
  const script = [
    'set -euo pipefail',
    'source /etc/profile.d/vesta.sh',
    'fixture_dir="$(mktemp -d)"',
    'fixture_file="$fixture_dir/value"',
    'cleanup() { rm -rf -- "$fixture_dir"; }',
    'trap cleanup EXIT',
    `printf %s ${shellEscape(encoded)} | base64 -d > "$fixture_file"`,
    'chmod 0600 "$fixture_file"',
    `"$VESTA/bin/v-add-docker-secret" ${shellEscape(owner)} ${shellEscape(project)} ${shellEscape(name)} "$fixture_file" >/dev/null`,
  ].join('\n');
  runRemoteBash(script);
}

function managedSecretPath(owner, project, name) {
  return `${getVestaRoot()}/data/users/${owner}/docker-projects/${project}/secrets/${name}`;
}

function cleanupRetainedFixturePaths(owner, project) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(owner)) {
    throw new Error(`Refusing retained-data cleanup for invalid owner: ${owner}`);
  }
  if (!/^pw-[a-z0-9-]+$/.test(project)) {
    throw new Error(`Refusing retained-data cleanup for non-Playwright project: ${project}`);
  }

  if (hasRemoteVestaRuntime()) {
    const script = [
      'set -euo pipefail',
      'source /etc/profile.d/vesta.sh',
      'readonly fixture_home_root=/home',
      `owner=${shellEscape(owner)}`,
      `project=${shellEscape(project)}`,
      'case "$project" in pw-[a-z0-9-]*) ;; *) echo "invalid Playwright project" >&2; exit 1 ;; esac',
      'backup_root="$VESTA/data/users/$owner/docker-project-backups/$project"',
      'data_root="$fixture_home_root/$owner/docker/$project"',
      'lock_file="$VESTA/data/users/$owner/docker-projects/.locks/$project.lock"',
      'expected_backup="$VESTA/data/users/$owner/docker-project-backups/$project"',
      'expected_data="$fixture_home_root/$owner/docker/$project"',
      '[ "$backup_root" = "$expected_backup" ] && [ "$data_root" = "$expected_data" ]',
      'if [ -e "$backup_root" ]; then [ -d "$backup_root" ] && [ ! -L "$backup_root" ]; rm -rf -- "$backup_root"; fi',
      'if [ -e "$data_root" ]; then [ -d "$data_root" ] && [ ! -L "$data_root" ]; rm -rf -- "$data_root"; fi',
      'rm -f -- "$lock_file"',
    ].join('\n');
    runRemoteBash(script);
    return;
  }

  const vestaRoot = getVestaRoot();
  const backupRoot = path.join(vestaRoot, 'data', 'users', owner, 'docker-project-backups', project);
  const dataRoot = path.join('/home', owner, 'docker', project);
  const lockFile = path.join(vestaRoot, 'data', 'users', owner, 'docker-projects', '.locks', `${project}.lock`);
  fs.rmSync(backupRoot, { recursive: true, force: true });
  fs.rmSync(dataRoot, { recursive: true, force: true });
  fs.rmSync(lockFile, { force: true });
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

function deleteContainer(owner, containerName) {
  let projectExists = true;
  try {
    runVestaCommand('v-list-docker-project', [owner, containerName, 'json']);
  } catch (error) {
    if (error && error.status === 3) {
      projectExists = false;
    } else {
      throw error;
    }
  }

  if (projectExists) {
    runVestaCommand('v-delete-docker-project', [owner, containerName, 'keep-data']);
  }
  if (/^pw-[a-z0-9-]+$/.test(containerName)) {
    cleanupRetainedFixturePaths(owner, containerName);
  }
  return projectExists;
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
  addComposeProjectSecret,
  changeComposeProject,
  cleanupRetainedFixturePaths,
  composeProjectDefinition,
  createComposeProject,
  createDisposableContainer,
  deleteContainer,
  hasExplicitLocalRuntimeTarget,
  hasLocalVestaRuntime,
  hasRemoteVestaRuntime,
  isLocalPanelTarget,
  managedSecretPath,
  readComposeProject,
  removeComposeServiceRuntime,
  remoteVestaSshArgs,
  remoteVestaSshExecution,
  runVestaCommand,
  withSeededAlert,
};
