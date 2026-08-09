#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers
mkdir -p "$VESTA/install/harbor" "$VESTA/nginx/conf"
cp "$HARBOR_REPO_ROOT/install/harbor/harbor-registry.conf.tpl" "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/ingress.sh"
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
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
[[ "$(grep -c 'proxy_set_header Cookie "";' "$rendered")" == 3 ]] || fail 'cookies are not stripped on every public route'
[[ "$(grep -c 'proxy_hide_header Set-Cookie;' "$rendered")" == 3 ]] || fail 'upstream cookies are not suppressed'
[[ "$(grep -c 'proxy_set_header X-Forwarded-For \$remote_addr;' "$rendered")" == 3 ]] || fail 'forwarded address chain is caller-controlled'
grep -q 'limit_conn_zone \$binary_remote_addr zone=vesta_harbor_registry:10m;' "$candidate" || fail 'registry connection zone missing'
grep -q 'log_format vesta_harbor_registry.*\$uri' "$candidate" || fail 'bounded secret-safe access format missing'
! grep -q '\$request_uri' "$candidate" || fail 'query-bearing URI entered registry log format'
grep -q 'proxy_request_buffering off;' "$rendered" || fail 'registry upload streaming missing'
grep -q 'client_max_body_size 0;' "$rendered" || fail 'registry upload body remains bounded by panel default'
fake_nginx="$HARBOR_TEST_ROOT/vesta-nginx"
nginx_log="$HARBOR_TEST_ROOT/vesta-nginx.log"
cat >"$fake_nginx" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$NGINX_LOG"
exit 0
SH
chmod 0755 "$fake_nginx"
export NGINX_LOG="$nginx_log" VX_HARBOR_PANEL_NGINX="$fake_nginx"
vx_harbor_panel_nginx_reload() { printf 'reload\n' >>"$nginx_log"; }
vx_harbor_ingress_activate "$rendered" "$candidate" "$activation" \
  || fail 'panel ingress activation failed'
grep -Fqx -- "-t -c $candidate" "$nginx_log" \
  || fail 'candidate was not tested with the Vesta panel nginx binary'
rerendered="$HARBOR_TEST_ROOT/rerendered.conf"
rerendered_candidate="$HARBOR_TEST_ROOT/rerendered-candidate.conf"
rerendered_activation="$HARBOR_TEST_ROOT/rerendered-activation.conf"
vx_harbor_ingress_render "$rerendered" "$rerendered_candidate" "$rerendered_activation" \
  || fail 'managed ingress could not be rendered idempotently'
[[ "$(grep -c 'include .*harbor-registry.conf;' "$rerendered_activation")" == 1 \
  && "$(grep -c 'limit_conn_zone .*vesta_harbor_registry' "$rerendered_activation")" == 1 ]] \
  || fail 'idempotent ingress render duplicated managed directives'
grep -Fqx -- "-t -c $VESTA/nginx/conf/nginx.conf" "$nginx_log" \
  || fail 'activated panel config was not tested explicitly'
grep -Fqx reload "$nginx_log" || fail 'Vesta panel nginx was not reloaded'
printf 'PASS: Harbor ingress\n'
