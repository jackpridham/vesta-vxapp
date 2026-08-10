#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
manifest="$HARBOR_REPO_ROOT/install/harbor/release-manifest.json"
jq -e '.images|length == 10 and all(.[];test("^sha256:[0-9a-f]{64}$"))' "$manifest" >/dev/null || fail 'runtime images are not all pinned'
for file in "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" "$HARBOR_REPO_ROOT/install/harbor/vesta-harbor.service"; do
  ! grep -Eiq 'network_mode:[[:space:]]*host|--privileged|privileged:[[:space:]]*true|docker\.sock|--publish|-p[[:space:]][0-9]' "$file" || fail "unsafe host boundary in $file"
done
grep -q -- '--project-name vesta-harbor' "$HARBOR_REPO_ROOT/install/harbor/vesta-harbor.service" || fail 'fixed Compose project missing'
grep -q '/run/vesta-harbor/proxy.sock' "$HARBOR_REPO_ROOT/install/harbor/harbor-registry.conf.tpl" || fail 'fixed socket missing'
grep -q 'listen unix:/run/vesta-harbor/proxy.sock' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'real Unix socket listener transform missing'
grep -q 'install -o 0 -g __VESTA_PANEL_GID__ -m 0750 -d /run/vesta-harbor' "$HARBOR_REPO_ROOT/install/harbor/vesta-harbor.service" || fail 'protected ingress directory is not panel-group bound'
grep -q "nginx='user nginx;" "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'proxy worker privilege drop missing'
grep -q 'chmod 0660' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'protected socket creation mode missing'
! grep -q '/bin/true' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'placeholder health or migration check remains'
grep -q 'pg_isready' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'database migration readiness check missing'
grep -q 'for attempt in {1..30}' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'bounded startup retries missing'
grep -q -- 'down --remove-orphans' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'failed candidate cleanup missing'
grep -q '/api/v2.0/health' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'bounded Harbor health check missing'
grep -q 'vx_harbor_health_observe_locked' "$HARBOR_REPO_ROOT/bin/v-list-user-harbor-registry" || fail 'tenant registry discovery does not refresh bounded health'
grep -q '/usr/bin/age' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'fixed age prerequisite missing'
grep -q '/usr/bin/age-keygen' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'fixed age-keygen prerequisite missing'
grep -q -- '--config -' "$HARBOR_REPO_ROOT/func/vx/harbor/api.sh" || fail 'credential probe does not stream curl config'
! grep -q -- '--user' "$HARBOR_REPO_ROOT/func/vx/harbor/api.sh" || fail 'credential material may enter curl argv'
! grep -q '\.probe-curl' "$HARBOR_REPO_ROOT/func/vx/harbor/api.sh" || fail 'credential probe retains a secret config file'
printf 'PASS: Harbor host boundary\n'
