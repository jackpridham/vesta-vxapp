#!/usr/bin/env bash

_vx_harbor_authority_schema_validate() {
    /usr/bin/python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/authority-schema.py" "$1" "$2" "$3"
}

vx_harbor_root() {
    printf '%s\n' "$VESTA/data/harbor"
}

vx_harbor_data_root() {
    printf '%s\n' '/var/lib/vesta-harbor'
}

_vx_harbor_authority_uid() {
    printf '0\n'
}

_vx_harbor_authority_gid() {
    printf '0\n'
}

_vx_harbor_require_root() {
    (( EUID == 0 ))
}

_vx_harbor_trust_anchor() {
    printf '%s\n' "$VESTA"
}

_vx_harbor_directory_prepare() {
    local path="$1"
    local trusted_parent="$2"
    local trust_anchor="${3:-}"
    local authority_uid authority_gid

    authority_uid="$(_vx_harbor_authority_uid)" || return 1
    authority_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ -n "$trust_anchor" ]] || trust_anchor="$(_vx_harbor_trust_anchor)" || return 1
    /usr/bin/python3 - "$path" "$trusted_parent" "$trust_anchor" \
        "$authority_uid" "$authority_gid" <<'PY'
import os
import stat
import sys

path, trusted_parent, trust_anchor = map(os.path.abspath, sys.argv[1:4])
authority_uid, authority_gid = map(int, sys.argv[4:6])
if path == trusted_parent or os.path.dirname(path) != trusted_parent:
    raise SystemExit(1)
if os.path.commonpath((trusted_parent, trust_anchor)) != trust_anchor:
    raise SystemExit(1)

def trusted_directory(candidate, exact_mode=None):
    value = os.lstat(candidate)
    if not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode):
        raise SystemExit(1)
    if value.st_uid != authority_uid or value.st_gid != authority_gid:
        raise SystemExit(1)
    mode = stat.S_IMODE(value.st_mode)
    if exact_mode is not None:
        if mode != exact_mode:
            raise SystemExit(1)
    elif mode & 0o022:
        raise SystemExit(1)
    return value

parent_value = trusted_directory(trust_anchor)
relative = os.path.relpath(trusted_parent, trust_anchor)
current = trust_anchor
if relative != ".":
    parts = relative.split(os.sep)
    for part in parts:
        if part in ("", ".", ".."):
            raise SystemExit(1)
        current = os.path.join(current, part)
        is_data_parent = (current == os.path.join(trust_anchor, "data"))
        parent_value = trusted_directory(
            current, None if is_data_parent else 0o700)
try:
    trusted_directory(path, 0o700)
    raise SystemExit(0)
except FileNotFoundError:
    pass

parent_fd = os.open(trusted_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    opened_parent = os.fstat(parent_fd)
    if (opened_parent.st_dev, opened_parent.st_ino) != (parent_value.st_dev,
                                                         parent_value.st_ino):
        raise SystemExit(1)
    name = os.path.basename(path)
    os.mkdir(name, 0o700, dir_fd=parent_fd)
    child_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                       dir_fd=parent_fd)
    try:
        os.fchown(child_fd, authority_uid, authority_gid)
        os.fchmod(child_fd, 0o700)
        value = os.fstat(child_fd)
        if (not stat.S_ISDIR(value.st_mode) or value.st_uid != authority_uid
                or value.st_gid != authority_gid
                or stat.S_IMODE(value.st_mode) != 0o700):
            raise SystemExit(1)
        os.fsync(child_fd)
    finally:
        os.close(child_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
}

_vx_harbor_secure_file_set() {
    /usr/bin/chown 0:0 "$1" && /usr/bin/chmod "$2" "$1"
}

_vx_harbor_fsync() {
    /usr/bin/python3 - "$1" <<'PY'
import os
import sys

flags = os.O_RDONLY
if os.path.isdir(sys.argv[1]):
    flags |= getattr(os, "O_DIRECTORY", 0)
descriptor = os.open(sys.argv[1], flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

_vx_harbor_secure_directory() {
    local path="$1"
    local expected_uid expected_gid
    [[ -d "$path" && ! -L "$path" ]] || return 1
    expected_uid="$(_vx_harbor_authority_uid)" || return 1
    expected_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:700" ]]
}

vx_harbor_secure_regular_file() {
    local path="$1"
    local mode="$2"
    local expected_uid expected_gid

    [[ "$mode" =~ ^0[0-7]{3}$ ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    expected_uid="$(_vx_harbor_authority_uid)" || return 1
    expected_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%h:%a' -- "$path" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:1:${mode#0}" ]]
}

vx_harbor_provider_state_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -e '
        type == "object"
        and (keys == [
            "INSTALLATION_ID", "LAST_BACKUP_ID", "LAST_HEALTH_AT",
            "LAST_RESTORE_TEST_AT", "LAST_UPGRADE", "MODE", "ORIGIN",
            "PINNED_VERSION", "RELEASE_MANIFEST_SHA256", "RUNNING_VERSION",
            "SCHEMA"
        ])
        and .SCHEMA == 1
        and .PINNED_VERSION == "v2.15.0"
        and (.MODE == "disabled" or .MODE == "managed")
        and ([
            .RUNNING_VERSION, .INSTALLATION_ID, .ORIGIN,
            .RELEASE_MANIFEST_SHA256, .LAST_HEALTH_AT, .LAST_BACKUP_ID,
            .LAST_RESTORE_TEST_AT, .LAST_UPGRADE
        ] | all(. == null or type == "string"))
    ' "$path" >/dev/null 2>&1
}

_vx_harbor_provider_prepare_after_preflight() {
    :
}

vx_harbor_json_write_atomic() {
    local destination="$1"
    local source="$2"
    local directory temporary

    _vx_harbor_require_root || return 1
    directory="$(dirname -- "$destination")" || return 1
    _vx_harbor_secure_directory "$directory" || return 1
    [[ -f "$source" && ! -L "$source" ]] || return 1
    if [[ -e "$destination" || -L "$destination" ]]; then
        vx_harbor_secure_regular_file "$destination" 0600 || return 1
    fi
    temporary="$(/usr/bin/mktemp "$directory/.harbor-json.XXXXXX")" || return 1
    if ! /usr/bin/jq -S . "$source" >"$temporary" \
        || ! _vx_harbor_secure_file_set "$temporary" 0600; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    if ! vx_harbor_secure_regular_file "$temporary" 0600 \
        || ! _vx_harbor_fsync "$temporary" \
        || ! _vx_harbor_json_write_phase fsync \
        || ! _vx_harbor_json_write_phase rename \
        || ! /usr/bin/mv -fT -- "$temporary" "$destination" \
        || ! _vx_harbor_fsync "$directory" \
        || ! vx_harbor_secure_regular_file "$destination" 0600; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

_vx_harbor_json_write_phase() { :; }

vx_harbor_provider_prepare() {
    local root source directory
    _vx_harbor_require_root || return 1
    root="$(vx_harbor_root)" || return 1

    # Authenticate every existing authority component before creating any
    # missing component. This keeps rejection paths entirely non-mutating.
    if [[ -e "$root" || -L "$root" ]]; then
        _vx_harbor_directory_prepare "$root" "$VESTA/data" || return 1
        for directory in owners observations operations rotations tombstones secrets release backups locks; do
            if [[ -e "$root/$directory" || -L "$root/$directory" ]]; then
                _vx_harbor_directory_prepare "$root/$directory" "$root" || return 1
            fi
        done
        if [[ -e "$root/provider.json" || -L "$root/provider.json" ]]; then
            vx_harbor_provider_state_validate "$root/provider.json" || return 1
        fi
    fi

    _vx_harbor_directory_prepare "$root" "$VESTA/data" || return 1
    _vx_harbor_secure_directory "$root" || return 1
    for directory in owners observations operations rotations tombstones secrets release backups locks; do
        _vx_harbor_directory_prepare "$root/$directory" "$root" || return 1
        _vx_harbor_secure_directory "$root/$directory" || return 1
    done
    _vx_harbor_provider_prepare_after_preflight || return 1
    if [[ -e "$root/provider.json" || -L "$root/provider.json" ]]; then
        vx_harbor_provider_state_validate "$root/provider.json"
        return $?
    fi

    source="$(/usr/bin/mktemp "$root/.provider-source.XXXXXX")" || return 1
    if ! /usr/bin/jq -n '{
        SCHEMA: 1,
        MODE: "disabled",
        PINNED_VERSION: "v2.15.0",
        RUNNING_VERSION: null,
        INSTALLATION_ID: null,
        ORIGIN: null,
        RELEASE_MANIFEST_SHA256: null,
        LAST_HEALTH_AT: null,
        LAST_BACKUP_ID: null,
        LAST_RESTORE_TEST_AT: null,
        LAST_UPGRADE: null
    }' >"$source" \
        || ! vx_harbor_json_write_atomic "$root/provider.json" "$source"; then
        /usr/bin/rm -f -- "$source"
        return 1
    fi
    /usr/bin/rm -f -- "$source"
    vx_harbor_provider_state_validate "$root/provider.json"
}

vx_harbor_provider_mode() {
    local root mode
    root="$(vx_harbor_root)" || return 1
    vx_harbor_provider_state_validate "$root/provider.json" || return 1
    mode="$(/usr/bin/jq -er '.MODE | select(. == "disabled" or . == "managed")' \
        "$root/provider.json" 2>/dev/null)" || return 1
    printf '%s\n' "$mode"
}

vx_harbor_provider_enabled() {
    [[ "$(vx_harbor_provider_mode)" == managed ]]
}

vx_harbor_provider_lock_acquire() {
    local mode="$1"
    local root lock_path requested_flag

    _vx_harbor_require_root || return 1
    [[ "$mode" == shared || "$mode" == exclusive ]] || return 1
    if [[ -n "${VX_HARBOR_PROVIDER_LOCK_FD:-}" ]]; then
        [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == "$mode" \
            && "${VX_HARBOR_PROVIDER_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ ]] || return 1
        VX_HARBOR_PROVIDER_LOCK_DEPTH=$((VX_HARBOR_PROVIDER_LOCK_DEPTH + 1))
        return 0
    fi
    root="$(vx_harbor_root)" || return 1
    _vx_harbor_directory_prepare "$root/locks" "$root" || return 1
    lock_path="$root/locks/provider.lock"
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
        vx_harbor_secure_regular_file "$lock_path" 0600 || return 1
    fi
    exec {VX_HARBOR_PROVIDER_LOCK_FD}>>"$lock_path" || return 1
    _vx_harbor_secure_file_set "$lock_path" 0600 || {
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    }
    vx_harbor_secure_regular_file "$lock_path" 0600 || {
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    }
    requested_flag=-s
    [[ "$mode" == exclusive ]] && requested_flag=-x
    if ! /usr/bin/flock "$requested_flag" "$VX_HARBOR_PROVIDER_LOCK_FD"; then
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    fi
    VX_HARBOR_PROVIDER_LOCK_MODE="$mode"
    VX_HARBOR_PROVIDER_LOCK_DEPTH=1
}

vx_harbor_provider_lock_release() {
    [[ "${VX_HARBOR_PROVIDER_LOCK_FD:-}" =~ ^[0-9]+$ \
        && "${VX_HARBOR_PROVIDER_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ \
        && ( "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == shared \
            || "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ) ]] || return 1
    if (( VX_HARBOR_PROVIDER_LOCK_DEPTH > 1 )); then
        VX_HARBOR_PROVIDER_LOCK_DEPTH=$((VX_HARBOR_PROVIDER_LOCK_DEPTH - 1))
        return 0
    fi
    /usr/bin/flock -u "$VX_HARBOR_PROVIDER_LOCK_FD" || return 1
    exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
    unset VX_HARBOR_PROVIDER_LOCK_FD VX_HARBOR_PROVIDER_LOCK_MODE \
        VX_HARBOR_PROVIDER_LOCK_DEPTH
}

vx_harbor_owner_state_path() {
    local owner="$1"
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    printf '%s/owners/%s.json\n' "$(vx_harbor_root)" "$owner"
}

_vx_harbor_authoritative_hostname() {
    local hostname_file

    if [[ -d /etc/sysconfig ]]; then
        hostname_file=/etc/sysconfig/network
        [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || return 1
        /usr/bin/awk -F= '
            $1 == "HOSTNAME" {
                value=substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]\047\"]+|[[:space:]\047\"]+$/, "", value)
                print value
                found++
            }
            END { if (found != 1) exit 1 }
        ' "$hostname_file"
        return
    fi

    hostname_file=/etc/hostname
    [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || return 1
    /usr/bin/awk 'NF { print; found++ } END { if (found != 1) exit 1 }' \
        "$hostname_file"
}

_vx_harbor_nginx_panel_endpoint() {
    local nginx_file="$1"
    local panel_root="$VESTA/web"
    local mime_types="$VESTA/nginx/conf/mime.types"
    local authority_uid authority_gid

    authority_uid="$(_vx_harbor_authority_uid)" || return 1
    authority_gid="$(_vx_harbor_authority_gid)" || return 1
    /usr/bin/python3 - "$nginx_file" "$panel_root" "$mime_types" \
        "$authority_uid" "$authority_gid" <<'PY'
import json
import os
import pathlib
import re
import stat
import sys

panel_root = sys.argv[2]
mime_types_path = pathlib.Path(sys.argv[3])
authority_uid, authority_gid = map(int, sys.argv[4:6])

def tokenize(config):
    tokens = []
    token = []
    quote = None
    escaped = False
    comment = False
    for character in config:
        if comment:
            if character == "\n":
                comment = False
            continue
        if quote:
            if escaped:
                token.append(character)
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            else:
                token.append(character)
            continue
        if character in "\"'":
            quote = character
        elif character == "#":
            comment = True
        elif character in "{};":
            if token:
                tokens.append("".join(token))
                token = []
            tokens.append(character)
        elif character.isspace():
            if token:
                tokens.append("".join(token))
                token = []
        else:
            token.append(character)
    if quote or escaped:
        raise SystemExit(1)
    if token:
        tokens.append("".join(token))
    return tokens

def parse(config):
    root = {"name": "root", "directives": [], "children": []}
    stack = [root]
    statement = []
    for value in tokenize(config):
        if value == ";":
            if not statement:
                raise SystemExit(1)
            stack[-1]["directives"].append(statement)
            statement = []
        elif value == "{":
            if not statement:
                raise SystemExit(1)
            child = {"name": statement[0], "args": statement[1:],
                     "directives": [], "children": []}
            stack[-1]["children"].append(child)
            stack.append(child)
            statement = []
        elif value == "}":
            if statement or len(stack) == 1:
                raise SystemExit(1)
            stack.pop()
        else:
            statement.append(value)
    if statement or len(stack) != 1:
        raise SystemExit(1)
    return root

config_path = pathlib.Path(sys.argv[1])
root = parse(config_path.read_text(encoding="utf-8"))

# Root/http includes can add server blocks and invalidate uniqueness. The
# authenticated static mime map is the sole safe include needed by the panel.
mime_includes = []
for context in [root] + [child for child in root["children"]
                         if child["name"] == "http"]:
    for item in context["directives"]:
        if item[0] == "include":
            if len(item) != 2 or "$" in item[1]:
                raise SystemExit(1)
            included = pathlib.Path(item[1])
            if not included.is_absolute():
                included = config_path.parent / included
            if os.path.abspath(included) != os.path.abspath(mime_types_path):
                raise SystemExit(1)
            mime_includes.append(mime_types_path)
if len(mime_includes) > 1:
    raise SystemExit(1)
if mime_includes:
    vesta_root = pathlib.Path(panel_root).parent
    current = vesta_root
    for part in ("nginx", "conf"):
        value = os.lstat(current)
        if (not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode)
                or value.st_uid != authority_uid or value.st_gid != authority_gid
                or stat.S_IMODE(value.st_mode) & 0o022):
            raise SystemExit(1)
        current = current / part
    value = os.lstat(current)
    if (not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode)
            or value.st_uid != authority_uid or value.st_gid != authority_gid
            or stat.S_IMODE(value.st_mode) & 0o022):
        raise SystemExit(1)
    mime_fd = os.open(mime_types_path, os.O_RDONLY | os.O_NOFOLLOW)
    value = os.fstat(mime_fd)
    if (not stat.S_ISREG(value.st_mode) or stat.S_ISLNK(value.st_mode)
            or value.st_nlink != 1 or value.st_uid != authority_uid
            or value.st_gid != authority_gid
            or stat.S_IMODE(value.st_mode) & 0o022):
        os.close(mime_fd)
        raise SystemExit(1)
    with os.fdopen(mime_fd, "r", encoding="utf-8") as mime_file:
        mime_root = parse(mime_file.read())
    if mime_root["directives"] or len(mime_root["children"]) != 1:
        raise SystemExit(1)
    types = mime_root["children"][0]
    if types["name"] != "types" or types["args"] or types["children"] \
            or not types["directives"]:
        raise SystemExit(1)
    for item in types["directives"]:
        if (len(item) < 2 or not re.fullmatch(r"[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+", item[0])
                or any(not re.fullmatch(r"[A-Za-z0-9.+_-]+", extension)
                       for extension in item[1:])):
            raise SystemExit(1)

servers = []
def visit(node):
    if node["name"] == "server":
        servers.append(node)
    for child in node["children"]:
        visit(child)
visit(root)

# A direct server include can inject panel-identifying or TLS authority.
if any(item[0] == "include" for server in servers
       for item in server["directives"]):
    raise SystemExit(1)

panel_servers = []
for server in servers:
    roots = [item[1] for item in server["directives"]
             if len(item) == 2 and item[0] == "root"]
    if roots == [panel_root]:
        panel_servers.append(server)
if len(panel_servers) != 1:
    raise SystemExit(1)
panel = panel_servers[0]

listeners = []
certificates = []
ssl_directives = []
for item in panel["directives"]:
    if item[0] in {"root", "listen", "server_name", "ssl", "ssl_certificate"} \
            and any("$" in value for value in item[1:]):
        raise SystemExit(1)
    if item[0] == "listen":
        if len(item) < 2:
            raise SystemExit(1)
        if item[2:].count("ssl") > 1:
            raise SystemExit(1)
        match = re.fullmatch(
            r"(?:(?:\[[0-9A-Fa-f:]+\]|[0-9.]+):)?([0-9]+)", item[1])
        if not match:
            raise SystemExit(1)
        listeners.append((int(match.group(1)), item[2:].count("ssl") == 1))
    elif item[0] == "ssl":
        ssl_directives.append(item[1:])
    elif item[0] == "ssl_certificate":
        if len(item) != 2:
            raise SystemExit(1)
        certificates.append(item[1])
if len(listeners) != 1 or not 1 <= listeners[0][0] <= 65535:
    raise SystemExit(1)
inline_tls = listeners[0][1]
if inline_tls:
    if ssl_directives:
        raise SystemExit(1)
elif ssl_directives != [["on"]]:
    raise SystemExit(1)
if len(certificates) != 1 or not certificates[0]:
    raise SystemExit(1)
print(json.dumps({"PORT": listeners[0][0], "CERTIFICATE": certificates[0]},
                 sort_keys=True, separators=(",", ":")))
PY
}

vx_harbor_origin_json() {
    local nginx_file hostname certificate endpoint port
    nginx_file="$VESTA/nginx/conf/nginx.conf"
    [[ -f "$nginx_file" && ! -L "$nginx_file" ]] || return 1
    hostname="$(_vx_harbor_authoritative_hostname)" || return 1
    hostname="${hostname%.}"
    hostname="${hostname,,}"
    [[ "$hostname" != localhost && "$hostname" == *.* \
        && ! "$hostname" =~ ^[0-9]+(\.[0-9]+){3}$ \
        && "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
        || return 1

    endpoint="$(_vx_harbor_nginx_panel_endpoint "$nginx_file")" || return 1
    port="$(/usr/bin/jq -er '.PORT' <<<"$endpoint")" || return 1
    certificate="$(/usr/bin/jq -er '.CERTIFICATE' <<<"$endpoint")" || return 1
    [[ "$certificate" == /* ]] || certificate="$VESTA/nginx/conf/$certificate"
    [[ -f "$certificate" && ! -L "$certificate" ]] || return 1
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/openssl x509 -in "$certificate" \
        -noout -checkend 0 >/dev/null 2>&1 || return 1
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/openssl x509 -in "$certificate" \
        -noout -checkhost "$hostname" >/dev/null 2>&1 || return 1
    /usr/bin/jq -n --arg hostname "$hostname" --argjson port "$port" '
        {HOSTNAME: $hostname, PORT: $port,
         REGISTRY: ($hostname + ":" + ($port | tostring)),
         ORIGIN: ("https://" + $hostname + ":" + ($port | tostring))}
    '
}
