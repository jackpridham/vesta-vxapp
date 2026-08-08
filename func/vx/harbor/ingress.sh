#!/usr/bin/env bash

vx_harbor_ingress_target() { printf '%s\n' "${VX_HARBOR_NGINX_TARGET:-$VESTA/nginx/conf/harbor-registry.conf}"; }
vx_harbor_systemd_target() { printf '%s\n' "${VX_HARBOR_SYSTEMD_TARGET:-/etc/systemd/system/vesta-harbor.service}"; }
vx_harbor_socket_path() { printf '%s\n' "${VX_HARBOR_SOCKET_PATH:-/run/vesta-harbor/proxy.sock}"; }

vx_harbor_ingress_render() {
    local destination="$1" endpoint port template
    endpoint="$(vx_harbor_origin_json)" || return 1
    port="$(/usr/bin/jq -er '.PORT' <<<"$endpoint")" || return 1
    template="$VESTA/install/harbor/harbor-registry.conf.tpl"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && -f "$template" && ! -L "$template" ]] || return 1
    /usr/bin/sed "s/__VESTA_TLS_PORT__/$port/g" "$template" >"$destination" || return 1
    /usr/bin/python3 - "$destination" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
locations=re.findall(r"location\s+([^\{]+)\{", text)
if [x.strip() for x in locations] != ["^~ /v2/", "= /service/token"]:
    raise SystemExit(1)
for forbidden in ("/api/", "metrics", "portal", "127.0.0.1", "docker.sock"):
    if forbidden in text.lower(): raise SystemExit(1)
if "http://unix:/run/vesta-harbor/proxy.sock" not in text:
    raise SystemExit(1)
PY
}

vx_harbor_ingress_activate() {
    local staged="$1" target directory temporary
    target="$(vx_harbor_ingress_target)" || return 1; directory="$(dirname "$target")"
    [[ -d "$directory" && ! -L "$directory" && -f "$staged" && ! -L "$staged" ]] || return 1
    temporary="$(/usr/bin/mktemp "$directory/.harbor-registry.conf.XXXXXX")" || return 1
    /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$staged" "$temporary" || return 1
    "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t || { /usr/bin/rm -f "$temporary"; return 1; }
    /usr/bin/mv -fT "$temporary" "$target" || return 1
    "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t || return 1
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service
}

vx_harbor_socket_validate() {
    local socket expected_uid expected_gid
    socket="$(vx_harbor_socket_path)" || return 1
    expected_uid="${VX_HARBOR_SOCKET_UID:-0}"; expected_gid="${VX_HARBOR_SOCKET_GID:-0}"
    [[ -S "$socket" && ! -L "$socket" ]] || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%a' "$socket")" == "$expected_uid:$expected_gid:660" ]]
}
