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
! grep -q '/bin/true' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'placeholder health or migration check remains'
grep -q 'pg_isready' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'database migration readiness check missing'
grep -q '/api/v2.0/health' "$HARBOR_REPO_ROOT/func/vx/harbor/install.sh" || fail 'bounded Harbor health check missing'
printf 'PASS: Harbor host boundary\n'
