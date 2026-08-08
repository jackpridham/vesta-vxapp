#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers
mkdir -p "$VESTA/install/harbor" "$VESTA/nginx/conf"
cp "$HARBOR_REPO_ROOT/install/harbor/harbor-registry.conf.tpl" "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/ingress.sh"
vx_harbor_origin_json() { printf '{"PORT":8083,"ORIGIN":"https://host.example:8083"}\n'; }
printf 'events {}\nhttp { server { root /srv/other; listen 9443 ssl; ssl_certificate /other.pem; } server { root %s/web; server_name host.example; listen 8083 ssl; ssl_certificate /panel.pem; location / { return 200; } } }\n' "$VESTA" >"$VESTA/nginx/conf/nginx.conf"
rendered="$HARBOR_TEST_ROOT/ingress.conf"; candidate="$HARBOR_TEST_ROOT/candidate.conf"; activation="$HARBOR_TEST_ROOT/activation.conf"
vx_harbor_ingress_render "$rendered" "$candidate" "$activation" || fail 'ingress render failed'
[[ "$(grep -c '^location ' "$rendered")" == 3 ]] || fail 'unexpected public locations'
grep -q 'location = /v2/' "$rendered" || fail 'exact /v2/ route missing'
grep -q 'location \^~ /v2/' "$rendered" || fail '/v2/ route missing'
grep -q 'location = /service/token' "$rendered" || fail 'token route missing'
! grep -Eiq '/api/|metrics|portal|127\.0\.0\.1|docker\.sock' "$rendered" || fail 'private Harbor route exposed'
grep -q 'http://unix:/run/vesta-harbor/proxy.sock' "$rendered" || fail 'Unix socket proxy missing'
grep -q "include $rendered;" "$candidate" || fail 'candidate include is not attached to panel server'
grep -q "include $VESTA/nginx/conf/harbor-registry.conf;" "$activation" || fail 'activation include is not attached to panel server'
grep -q "root $VESTA/web" "$candidate" || fail 'candidate lost authoritative panel root'
grep -q 'listen 8083 ssl' "$candidate" || fail 'candidate lost authoritative panel port'
grep -q 'ssl_certificate /panel.pem' "$candidate" || fail 'candidate lost authoritative panel certificate'
! grep -Eiq '/api/|metrics|portal' "$rendered" || fail 'private route exposed'
printf 'PASS: Harbor ingress\n'
