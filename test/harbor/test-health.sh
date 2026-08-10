#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; new_vesta_root; trap cleanup_vesta_root EXIT; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ :; }; _vx_harbor_authority_uid(){ id -u; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }; vx_harbor_provider_prepare
tmp="$(mktemp "$(vx_harbor_root)/.provider.XXXXXX")"; jq '.MODE="managed"' "$(vx_harbor_root)/provider.json" >"$tmp"; vx_harbor_json_write_atomic "$(vx_harbor_root)/provider.json" "$tmp"; rm -f "$tmp"

mkdir -p "$VESTA/nginx/conf" "$VESTA/web"
certificate="$HARBOR_TEST_ROOT/panel.pem"; key="$HARBOR_TEST_ROOT/panel.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 60 \
    -subj '/CN=panel.example.com' -addext 'subjectAltName=DNS:panel.example.com' \
    -keyout "$key" -out "$certificate" >/dev/null 2>&1
chmod 0660 "$certificate"
printf 'http { server { root %s/web; listen 8083 ssl; ssl_certificate %s; } }\n' \
    "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
_vx_harbor_authoritative_hostname(){ printf 'panel.example.com\n'; }
certificate_observation="$(_vx_harbor_certificate_observe)" \
    || fail 'Vesta-owned panel certificate was rejected'
jq -e '.STATE=="valid" and .HOSTNAME_VALID and (.EXPIRES_AT|type=="string")' \
    <<<"$certificate_observation" >/dev/null \
    || fail 'Vesta-owned panel certificate observation is invalid'
[[ "$(stat -c %a "$certificate")" == 660 ]] \
    || fail 'panel certificate mode was mutated'
if grep -Eq 'strptime|mktime' "$VESTA/func/vx/harbor/health.sh"; then
    fail 'certificate observation depends on jq version-specific date parsing'
fi

certificate_link="$HARBOR_TEST_ROOT/panel-link.pem"
ln -s "$certificate" "$certificate_link"
printf 'http { server { root %s/web; listen 8083 ssl; ssl_certificate %s; } }\n' \
    "$VESTA" "$certificate_link" >"$VESTA/nginx/conf/nginx.conf"
if _vx_harbor_certificate_observe >/dev/null 2>&1; then
    fail 'symlinked panel certificate was accepted'
fi
rm -f "$certificate_link"

certificate_link="$HARBOR_TEST_ROOT/panel-hardlink.pem"
ln "$certificate" "$certificate_link"
printf 'http { server { root %s/web; listen 8083 ssl; ssl_certificate %s; } }\n' \
    "$VESTA" "$certificate_link" >"$VESTA/nginx/conf/nginx.conf"
if _vx_harbor_certificate_observe >/dev/null 2>&1; then
    fail 'hard-linked panel certificate was accepted'
fi
rm -f "$certificate_link"

vx_harbor_api_health(){ printf '{}'; }; vx_harbor_api_volume(){ printf '{"storage":{"used":12,"total":100}}'; }; _vx_harbor_certificate_observe(){ printf '{"STATE":"valid","EXPIRES_AT":"2030-01-01T00:00:00Z","HOSTNAME_VALID":true}'; }
vx_harbor_api_quota_get(){ printf '{"id":1,"used":{"storage":0}}'; }; vx_harbor_api_project_robot_get(){ printf '{}'; }
vx_harbor_provider_lock_acquire shared; result="$(vx_harbor_health_observe_locked)"; vx_harbor_provider_lock_release
jq -e '.SCHEMA==1 and .HEALTH=="healthy" and .STORAGE.USED_BYTES==12 and .CERTIFICATE.HOSTNAME_VALID and (.OBSERVED_AT|type=="string")' <<<"$result" >/dev/null || fail 'bounded health observation invalid'
grep -Eq 'password|secret|/run/vesta' <<<"$result" && fail 'health observation leaked protected detail'
jq -e 'keys==["HEALTH","OBSERVED_AT","SCHEMA"] and .SCHEMA==1' "$(vx_harbor_root)/observations/provider.json" >/dev/null || fail 'provider discovery observation schema regressed'
printf 'PASS: bounded Harbor health observations\n'
