#!/usr/bin/env bash

vx_harbor_ingress_target() { printf '%s\n' "${VX_HARBOR_NGINX_TARGET:-$VESTA/nginx/conf/harbor-registry.conf}"; }
vx_harbor_nginx_main() { printf '%s\n' "${VX_HARBOR_NGINX_MAIN:-$VESTA/nginx/conf/nginx.conf}"; }
vx_harbor_systemd_target() { printf '%s\n' "${VX_HARBOR_SYSTEMD_TARGET:-/etc/systemd/system/vesta-harbor.service}"; }
vx_harbor_socket_path() { printf '%s\n' "${VX_HARBOR_SOCKET_PATH:-/run/vesta-harbor/proxy.sock}"; }
vx_harbor_panel_nginx_binary() { printf '%s\n' "${VX_HARBOR_PANEL_NGINX:-$VESTA/nginx/sbin/vesta-nginx}"; }

vx_harbor_panel_nginx_test() {
    local config="$1" binary
    binary="$(vx_harbor_panel_nginx_binary)" || return 1
    [[ -x "$binary" && -f "$binary" && ! -L "$binary" \
        && -f "$config" && ! -L "$config" ]] || return 1
    "$binary" -t -c "$config"
}

vx_harbor_panel_nginx_reload() {
    local binary pid_file pid executable
    binary="$(vx_harbor_panel_nginx_binary)" || return 1
    pid_file="${VX_HARBOR_PANEL_NGINX_PID_FILE:-/var/run/vesta-nginx.pid}"
    [[ -x "$binary" && -f "$binary" && ! -L "$binary" \
        && -f "$pid_file" && ! -L "$pid_file" \
        && "$(/usr/bin/stat -c '%u:%g:%a' "$pid_file")" == 0:0:644 ]] || return 1
    IFS= read -r pid <"$pid_file" || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    executable="$(/usr/bin/readlink -f "/proc/$pid/exe")" || return 1
    [[ "$executable" == "$binary" ]] || return 1
    /bin/kill -HUP "$pid"
}

vx_harbor_ingress_render() {
    local destination="$1" candidate_main="$2" activation_main="$3" endpoint port template main target
    endpoint="$(vx_harbor_origin_json)" || return 1
    port="$(/usr/bin/jq -er '.PORT' <<<"$endpoint")" || return 1
    template="$VESTA/install/harbor/harbor-registry.conf.tpl"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && -f "$template" && ! -L "$template" ]] || return 1
    /usr/bin/sed "s/__VESTA_TLS_PORT__/$port/g" "$template" >"$destination" || return 1
    /usr/bin/python3 - "$destination" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
locations=re.findall(r"location\s+([^\{]+)\{", text)
if [x.strip() for x in locations] != ["= /v2/", "^~ /v2/", "= /service/token"]:
    raise SystemExit(1)
for forbidden in ("/api/", "metrics", "portal", "127.0.0.1", "docker.sock"):
    if forbidden in text.lower(): raise SystemExit(1)
if "http://unix:/run/vesta-harbor/proxy.sock" not in text:
    raise SystemExit(1)
PY
    main="$(vx_harbor_nginx_main)"; target="$(vx_harbor_ingress_target)"
    [[ -f "$main" && ! -L "$main" ]] || return 1
    /usr/bin/python3 - "$main" "$candidate_main" "$activation_main" "$destination" "$target" "$VESTA/web" <<'PY'
import pathlib,re,sys
source,candidate,activation,staged_include,target_include,panel_root=map(pathlib.Path,sys.argv[1:])
text=source.read_text(); blocks=[]
for match in re.finditer(r'\bserver\s*\{', text):
    depth=1; pos=match.end(); quote=None
    while pos < len(text) and depth:
        c=text[pos]
        if quote:
            if c==quote and text[pos-1] != '\\': quote=None
        elif c in "'\"": quote=c
        elif c=='#':
            pos=text.find('\n',pos)
            if pos < 0: break
        elif c=='{': depth+=1
        elif c=='}': depth-=1
        pos+=1
    if depth==0: blocks.append((match.start(),pos,text[match.start():pos]))
needle=re.compile(r'\broot\s+'+re.escape(str(panel_root))+r'\s*;')
matches=[b for b in blocks if needle.search(b[2])]
if len(matches)!=1: raise SystemExit(1)
start,end,block=matches[0]
insert=end-1
global_directives=(
    '    limit_conn_zone $binary_remote_addr zone=vesta_harbor_registry:10m;\n'
    "    log_format vesta_harbor_registry '$remote_addr - $request_method $uri $status $body_bytes_sent';\n"
)
installed_include='    include '+str(target_include)+';\n'
has_managed_tokens=('harbor-registry.conf' in text
                    or 'vesta_harbor_registry' in text)
if has_managed_tokens:
    if (text.count(installed_include) != 1
            or block.count(installed_include) != 1
            or text.count(global_directives) != 1):
        raise SystemExit(1)
    candidate.write_text(text.replace(
        installed_include, '    include '+str(staged_include)+';\n', 1))
    activation.write_text(text)
    raise SystemExit(0)
def build(path):
    with_global=text[:start]+global_directives+text[start:]
    adjusted_insert=insert+len(global_directives)
    return with_global[:adjusted_insert]+'    include '+str(path)+';\n'+with_global[adjusted_insert:]
candidate.write_text(build(staged_include)); activation.write_text(build(target_include))
PY
}

vx_harbor_ingress_activate() {
    local staged="$1" candidate_main="$2" activation_main="$3" target main directory temporary main_temporary
    target="$(vx_harbor_ingress_target)" || return 1; directory="$(dirname "$target")"
    main="$(vx_harbor_nginx_main)"
    [[ -d "$directory" && ! -L "$directory" && -f "$staged" && ! -L "$staged" \
        && -f "$candidate_main" && ! -L "$candidate_main" && -f "$activation_main" && ! -L "$activation_main" ]] || return 1
    vx_harbor_panel_nginx_test "$candidate_main" || return 1
    temporary="$(/usr/bin/mktemp "$directory/.harbor-registry.conf.XXXXXX")" || return 1
    main_temporary="$(/usr/bin/mktemp "$directory/.nginx.conf.XXXXXX")" || { /usr/bin/rm -f "$temporary"; return 1; }
    /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$staged" "$temporary" || return 1
    /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$activation_main" "$main_temporary" || return 1
    /usr/bin/mv -fT "$temporary" "$target" || return 1
    /usr/bin/mv -fT "$main_temporary" "$main" || return 1
    vx_harbor_panel_nginx_test "$main" || return 1
    vx_harbor_panel_nginx_reload
}

vx_harbor_socket_validate() {
    local socket expected_uid expected_gid
    socket="$(vx_harbor_socket_path)" || return 1
    expected_uid="${VX_HARBOR_SOCKET_UID:-0}"
    expected_gid="${VX_HARBOR_SOCKET_GID:-$(_vx_harbor_panel_worker_gid)}"
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -S "$socket" && ! -L "$socket" ]] || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%a' "$socket")" == "$expected_uid:$expected_gid:660" ]]
}
