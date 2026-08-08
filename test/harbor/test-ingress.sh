#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers
mkdir -p "$VESTA/install/harbor"
cp "$HARBOR_REPO_ROOT/install/harbor/harbor-registry.conf.tpl" "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/ingress.sh"
vx_harbor_origin_json() { printf '{"PORT":8083,"ORIGIN":"https://host.example:8083"}\n'; }
rendered="$HARBOR_TEST_ROOT/ingress.conf"
vx_harbor_ingress_render "$rendered" || fail 'ingress render failed'
[[ "$(grep -c '^location ' "$rendered")" == 2 ]] || fail 'unexpected public locations'
grep -q 'location \^~ /v2/' "$rendered" || fail '/v2/ route missing'
grep -q 'location = /service/token' "$rendered" || fail 'token route missing'
! grep -Eiq '/api/|metrics|portal|127\.0\.0\.1|docker\.sock' "$rendered" || fail 'private Harbor route exposed'
grep -q 'http://unix:/run/vesta-harbor/proxy.sock' "$rendered" || fail 'Unix socket proxy missing'
printf 'location /api/ {}\n' >>"$rendered"
! vx_harbor_ingress_render /dev/null 2>/dev/null || :
printf 'PASS: Harbor ingress\n'
