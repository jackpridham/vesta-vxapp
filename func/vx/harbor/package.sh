#!/usr/bin/env bash

VX_HARBOR_OBSERVATION_MAX_AGE_SECONDS=300
VX_HARBOR_OBSERVATION_MAX_FUTURE_SECONDS=30
VX_HARBOR_TRANSITION_TTL_SECONDS=900

_vx_harbor_now_epoch() {
    date -u +%s
}

vx_harbor_registry_usage_set() {
    local owner="$1" used_mb="$2"
    [[ "$used_mb" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    update_user_value "$owner" '$U_DOCKER_REGISTRY_MB' "$used_mb"
}

_vx_harbor_transition_require_locks() {
    local owner="$1"
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == shared \
        || "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    if declare -F vx_compose_shell_access_lock_acquire >/dev/null; then
        [[ "${VX_COMPOSE_ACCESS_LOCK_OWNER:-}" == "$owner" ]]
    fi
}

_vx_harbor_transition_paths() {
    local owner="$1" root
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    root="$(vx_harbor_root)/transactions" || return 1
    _vx_harbor_secure_directory "$root" || return 1
    VX_HARBOR_TRANSITION_JOURNAL="$root/$owner.json"
    VX_HARBOR_TRANSITION_SNAPSHOT="$root/$owner.user.conf.before"
    VX_HARBOR_TRANSITION_AFTER="$root/$owner.user.conf.after"
    VX_HARBOR_TRANSITION_SWAP="$root/$owner.user.conf.swap"
    VX_HARBOR_TRANSITION_STALE="$root/$owner.user.conf.stale"
}

_vx_harbor_transition_key() {
    local root key secrets
    root="$(vx_harbor_root)" || return 1
    secrets="$root/secrets"
    key="$secrets/package-transition.key"
    _vx_harbor_secure_directory "$secrets" || return 1
    /usr/bin/python3 - "$key" "$secrets" <<'PY'
import os
import sys

path, directory = sys.argv[1:]
try:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit(0)
try:
    os.write(descriptor, os.urandom(32).hex().encode("ascii") + b"\n")
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory_descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
PY
    vx_harbor_secure_regular_file "$key" 0600 || return 1
    [[ "$(/usr/bin/wc -l <"$key")" == 1 ]] || return 1
    /usr/bin/grep -Eq '^[0-9a-f]{64}$' "$key" || return 1
    printf '%s\n' "$key"
}

_vx_harbor_transition_sign() {
    local payload="$1" key
    key="$(_vx_harbor_transition_key)" || return 1
    /usr/bin/python3 - "$key" "$payload" <<'PY'
import hashlib
import hmac
import sys

with open(sys.argv[1], "rb") as key_file:
    key = key_file.read().strip()
payload = sys.argv[2].encode("ascii")
sys.stdout.write(hmac.new(key, payload, hashlib.sha256).hexdigest() + "\n")
PY
}

_vx_harbor_transition_token_create() {
    local owner="$1" operation_id="$2" expires_at="$3" generation="$4"
    local payload signature
    payload="$({ /usr/bin/printf '%s|%s|%s|%s' \
        "$owner" "$operation_id" "$expires_at" "$generation"; } \
        | /usr/bin/base64 -w0)" || return 1
    signature="$(_vx_harbor_transition_sign "$payload")" || return 1
    printf '%s.%s\n' "$payload" "$signature"
}

_vx_harbor_transition_token_read() {
    local owner="$1" token="$2" payload signature expected decoded now
    payload="${token%%.*}"
    signature="${token#*.}"
    [[ -n "$payload" && "$signature" != "$token" ]] || return 1
    expected="$(_vx_harbor_transition_sign "$payload")" || return 1
    [[ "$signature" == "$expected" ]] || return 1
    decoded="$(/usr/bin/base64 -d <<<"$payload")" || return 1
    IFS='|' read -r VX_HARBOR_TRANSITION_OWNER \
        VX_HARBOR_TRANSITION_OPERATION_ID VX_HARBOR_TRANSITION_EXPIRES_AT \
        VX_HARBOR_TRANSITION_GENERATION <<<"$decoded"
    [[ "$VX_HARBOR_TRANSITION_OWNER" == "$owner" \
        && "$VX_HARBOR_TRANSITION_OPERATION_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_HARBOR_TRANSITION_EXPIRES_AT" =~ ^[0-9]+$ ]] || return 1
    now="$(_vx_harbor_now_epoch)" || return 1
    (( now <= VX_HARBOR_TRANSITION_EXPIRES_AT ))
}

_vx_harbor_observation_json() {
    local owner="$1" path now
    path="$(vx_harbor_root)/observations/$owner.json"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    now="$(date -u +%s)" || return 1
    /usr/bin/python3 - "$path" "$now" \
        "$VX_HARBOR_OBSERVATION_MAX_AGE_SECONDS" \
        "$VX_HARBOR_OBSERVATION_MAX_FUTURE_SECONDS" <<'PY'
import datetime
import json
import re
import sys

path, now, max_age, max_future = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    value = json.load(source)
if not {"USED_MB", "OBSERVED_AT", "GENERATION"}.issubset(value):
    raise SystemExit(1)
used = value["USED_MB"]
generation = value["GENERATION"]
observed_at = value["OBSERVED_AT"]
if isinstance(used, bool) or not isinstance(used, int) or used < 0:
    raise SystemExit(1)
if not isinstance(generation, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", generation):
    raise SystemExit(1)
if not isinstance(observed_at, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", observed_at):
    raise SystemExit(1)
try:
    observed = int(datetime.datetime.strptime(observed_at, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc).timestamp())
except ValueError:
    raise SystemExit(1)
age = int(now) - observed
if age > int(max_age) or age < -int(max_future):
    raise SystemExit(1)
print(json.dumps({key: value[key] for key in
                  ("USED_MB", "OBSERVED_AT", "GENERATION")},
                 sort_keys=True, separators=(",", ":")))
PY
}

_vx_harbor_current_owner_quota() {
    local owner="$1" path
    path="$(vx_harbor_owner_state_path "$owner")" || return 1
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -er '.QUOTA_MB | select(. == "unlimited" or
        (type == "number" and floor == . and . >= 0))' "$path" 2>/dev/null
}

_vx_harbor_transition_quota_apply() {
    declare -F vx_harbor_owner_quota_set >/dev/null || return 1
    vx_harbor_owner_quota_set "$1" "$2" "$3" "$4" "$5" "$6"
}

_vx_harbor_transition_checkpoint() {
    :
}

_vx_harbor_transition_journal_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -e '
        type == "object" and (keys == [
          "ACCESS_COMPLETED","APPLIED_DIGEST","CREATED_AT","DENY_MARKER_PRESENT","DISK_QUOTA_COMPENSATED","DISK_QUOTA_PENDING","EXPIRES_AT","GROUP_MEMBER",
          "MODE","NEW_DIGEST","NEW_QUOTA","OBSERVATION_GENERATION",
          "OBSERVED_AT","OLD_DIGEST","OLD_PACKAGE","OLD_QUOTA","OLD_SHELL","OPERATION_ID",
          "OWNER","PACKAGE","SCHEMA","STATE","SWAP_BASIS_DEVICE","SWAP_BASIS_DIGEST","SWAP_BASIS_INODE",
          "SWAP_CANDIDATE_DEVICE","SWAP_CANDIDATE_DIGEST","SWAP_CANDIDATE_INODE",
          "SWAP_DISPLACED_DEVICE","SWAP_DISPLACED_DIGEST","SWAP_DISPLACED_INODE",
          "SWAP_FRESH_DEVICE","SWAP_FRESH_DIGEST","SWAP_FRESH_INODE","SWAP_FRESH_LOCATION","SWAP_INTENT","SWAP_PHASE",
          "TRIGGER_COMPENSATED","TRIGGER_PENDING",
          "USER_CONF_DEVICE","USER_CONF_INODE","USER_CONF_PATH"
        ]) and .SCHEMA == 1
        and (.STATE == "prepared" or .STATE == "quota-applied"
             or .STATE == "user-conf-applied" or .STATE == "side-effects-applied"
             or .STATE == "committed" or .STATE == "access-completed")
        and (.MODE == "disabled" or .MODE == "managed")
        and (.OWNER | type == "string" and test("^[a-z0-9][a-z0-9_-]{0,31}$"))
        and (.OPERATION_ID | type == "string" and test("^[a-f0-9]{32}$"))
        and (.OLD_DIGEST | type == "string" and test("^[a-f0-9]{64}$"))
        and (.NEW_DIGEST | type == "string" and test("^[a-f0-9]{64}$"))
        and (.CREATED_AT | type == "number" and floor == . and . >= 0)
        and (.CREATED_AT as $created |
             (.EXPIRES_AT | type == "number" and floor == . and . >= $created))
        and (.USER_CONF_DEVICE | type == "number" and floor == . and . >= 0)
        and (.USER_CONF_INODE | type == "number" and floor == . and . > 0)
        and (.PACKAGE | type == "string" and test("^[A-Za-z0-9._-]+$"))
        and (.OLD_SHELL | type == "string" and test("^/[^\\r\\n]+$"))
        and ((.OLD_QUOTA == "unlimited") or
             (.OLD_QUOTA | type == "number" and floor == . and . >= 0))
        and ((.NEW_QUOTA == "unlimited") or
             (.NEW_QUOTA | type == "number" and floor == . and . >= 0))
        and (if .MODE == "managed" then
               (.OBSERVATION_GENERATION | type == "string" and
                 test("^[A-Za-z0-9._:-]{1,128}$")) and
               (.OBSERVED_AT | type == "string" and
                 test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
             else .OBSERVATION_GENERATION == null and .OBSERVED_AT == null end)
        and (.GROUP_MEMBER | type == "boolean")
        and (.DENY_MARKER_PRESENT | type == "boolean")
        and (.ACCESS_COMPLETED | type == "boolean")
        and ((.STATE == "access-completed" and .ACCESS_COMPLETED == true)
             or (.STATE != "access-completed" and .ACCESS_COMPLETED == false))
        and (.DISK_QUOTA_PENDING | type == "boolean")
        and (.DISK_QUOTA_COMPENSATED | type == "boolean")
        and (if .DISK_QUOTA_COMPENSATED then .DISK_QUOTA_PENDING else true end)
        and (.TRIGGER_PENDING | type == "boolean")
        and (.TRIGGER_COMPENSATED | type == "boolean")
        and (if .TRIGGER_COMPENSATED then .TRIGGER_PENDING else true end)
        and (.OLD_PACKAGE | type == "string" and test("^[a-zA-Z0-9._-]+$"))
        and (.SWAP_PHASE == "none" or .SWAP_PHASE == "candidate-ready"
             or .SWAP_PHASE == "exchanged" or .SWAP_PHASE == "superseded")
        and (.SWAP_INTENT == null or .SWAP_INTENT == "apply"
             or .SWAP_INTENT == "rollback" or .SWAP_INTENT == "commit")
        and ([.SWAP_BASIS_DEVICE,.SWAP_BASIS_INODE,
              .SWAP_CANDIDATE_DEVICE,.SWAP_CANDIDATE_INODE,
              .SWAP_DISPLACED_DEVICE,.SWAP_DISPLACED_INODE,
              .SWAP_FRESH_DEVICE,.SWAP_FRESH_INODE] |
             all(. == null or (type == "number" and floor == . and . >= 0)))
        and ([.SWAP_BASIS_DIGEST,.SWAP_CANDIDATE_DIGEST,
              .SWAP_DISPLACED_DIGEST,.SWAP_FRESH_DIGEST] |
             all(. == null or (type == "string" and test("^[a-f0-9]{64}$"))))
        and (.SWAP_FRESH_LOCATION == null or .SWAP_FRESH_LOCATION == "current"
             or .SWAP_FRESH_LOCATION == "swap")
        and (.APPLIED_DIGEST == null or
             (.APPLIED_DIGEST | type == "string" and test("^[a-f0-9]{64}$")))
    ' "$path" >/dev/null 2>&1
}

_vx_harbor_transition_journal_state_set() {
    local state="$1" source
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! /usr/bin/jq --arg state "$state" '.STATE = $state' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

_vx_harbor_transition_snapshot_create() {
    local source="$1" destination="$2" directory
    directory="$(dirname -- "$destination")" || return 1
    /usr/bin/python3 - "$source" "$destination" "$directory" <<'PY'
import os
import stat
import sys
import hashlib

source, destination, directory = sys.argv[1:]
source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
try:
    source_stat = os.fstat(source_fd)
    if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_nlink != 1:
        raise SystemExit(1)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    destination_fd = os.open(destination, flags, 0o600)
    digest = hashlib.sha256()
    try:
        while True:
            block = os.read(source_fd, 65536)
            if not block:
                break
            digest.update(block)
            os.write(destination_fd, block)
        final_stat = os.fstat(source_fd)
        identity = (source_stat.st_dev, source_stat.st_ino,
                    source_stat.st_size, source_stat.st_mtime_ns)
        if identity != (final_stat.st_dev, final_stat.st_ino,
                        final_stat.st_size, final_stat.st_mtime_ns):
            raise BlockingIOError("source changed")
        os.fchmod(destination_fd, 0o600)
        os.fsync(destination_fd)
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
print(f"{source_stat.st_dev}:{source_stat.st_ino}:{digest.hexdigest()}")
PY
}

_vx_harbor_transition_user_conf_matches_capture() {
    local path="$1" device="$2" inode="$3" digest="$4"
    /usr/bin/python3 - "$path" "$device" "$inode" "$digest" <<'PY'
import hashlib
import os
import sys

path, device, inode, expected = sys.argv[1:]
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    before = os.fstat(descriptor)
    value = hashlib.sha256()
    while True:
        block = os.read(descriptor, 65536)
        if not block:
            break
        value.update(block)
    after = os.fstat(descriptor)
finally:
    os.close(descriptor)
if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != \
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
    raise SystemExit(1)
if before.st_dev != int(device) or before.st_ino != int(inode):
    raise SystemExit(1)
if value.hexdigest() != expected:
    raise SystemExit(1)
PY
}

_vx_harbor_transition_user_conf_restore() {
    local destination="$1" snapshot="$2" directory temporary
    directory="$(dirname -- "$destination")" || return 1
    [[ -f "$destination" && ! -L "$destination" ]] || return 1
    temporary="$(mktemp "$directory/.user.conf.rollback.XXXXXX")" || return 1
    if ! cp -p -- "$snapshot" "$temporary" \
        || ! chmod --reference="$destination" "$temporary" \
        || ! chown --reference="$destination" "$temporary" \
        || ! _vx_harbor_fsync "$temporary" \
        || ! mv -fT -- "$temporary" "$destination" \
        || ! _vx_harbor_fsync "$directory"; then
        rm -f -- "$temporary"
        return 1
    fi
}

_vx_harbor_transition_user_conf_merge() {
    local current="$1" authority="$2" swap="${3:-}" intent="${4:-apply}" directory
    directory="$(dirname -- "$current")" || return 1
    [[ -n "$swap" ]] || swap="$directory/.user.conf.harbor.swap"
    /usr/bin/python3 - "$current" "$authority" "$directory" "$swap" \
        "$VX_HARBOR_TRANSITION_JOURNAL" "$intent" <<'PY'
import ctypes
import hashlib
import json
import os
import re
import stat
import sys

current_path, authority_path, directory, swap_path, journal_path, intent = sys.argv[1:]
controlled = {
    "PACKAGE", "WEB_TEMPLATE", "BACKEND_TEMPLATE", "PROXY_TEMPLATE",
    "DNS_TEMPLATE", "WEB_DOMAINS", "WEB_ALIASES", "DNS_DOMAINS",
    "DNS_RECORDS", "MAIL_DOMAINS", "MAIL_ACCOUNTS", "DATABASES",
    "CRON_JOBS", "DOCKER_CONTAINERS", "DOCKER_PROJECTS",
    "DOCKER_SERVICES", "DOCKER_CPUS", "DOCKER_MEMORY_MB", "DOCKER_PIDS",
    "DOCKER_STORAGE_MB", "DOCKER_REGISTRY_MB", "DOCKER_PORTS",
    "DOCKER_SECRETS", "DOCKER_VOLUMES", "DISK_QUOTA", "BANDWIDTH",
    "NS", "SHELL", "BACKUPS"
}

assignment = re.compile(rb"^([A-Z][A-Z0-9_]*)=(?:'[^'\r\n]*'|[^\r\n]*)$")

def read_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise RuntimeError("unsafe file")
        chunks = []
        while True:
            block = os.read(descriptor, 65536)
            if not block:
                break
            chunks.append(block)
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise BlockingIOError("changed while reading")
        return b"".join(chunks), before
    finally:
        os.close(descriptor)

authority_data, _ = read_regular(authority_path)
authority_values = {}
for line in authority_data.splitlines():
    match = assignment.fullmatch(line)
    if not match:
        raise SystemExit(1)
    key = match.group(1).decode("ascii")
    if key in controlled:
        if key in authority_values:
            raise SystemExit(1)
        authority_values[key] = line
if not authority_values:
    raise SystemExit(1)

def fsync_directories():
    for path in {directory, os.path.dirname(swap_path)}:
        directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

def journal_update(**changes):
    descriptor = os.open(journal_path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        journal = json.loads(os.read(descriptor, 1048576))
    finally:
        os.close(descriptor)
    journal.update(changes)
    journal_directory = os.path.dirname(journal_path)
    temporary = os.path.join(journal_directory,
                             ".journal.swap.%d" % os.getpid())
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        payload = (json.dumps(journal, separators=(",", ":"), sort_keys=True) + "\n").encode()
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, journal_path)
    descriptor = os.open(journal_directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

for _ in range(8):
    try:
        current_data, current_stat = read_regular(current_path)
    except BlockingIOError:
        continue
    output = []
    emitted = set()
    valid = True
    for line in current_data.splitlines():
        match = assignment.fullmatch(line)
        if not match:
            valid = False
            break
        key = match.group(1).decode("ascii")
        if key in controlled:
            if key in emitted:
                valid = False
                break
            output.append(authority_values.get(key, line))
            emitted.add(key)
        else:
            output.append(line)
    if not valid:
        raise SystemExit(1)
    for key in sorted(authority_values.keys() - emitted):
        output.append(authority_values[key])
    merged = b"\n".join(output) + b"\n"
    try:
        descriptor = os.open(swap_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        raise SystemExit(1)
    try:
        os.fchmod(descriptor, stat.S_IMODE(current_stat.st_mode))
        os.fchown(descriptor, current_stat.st_uid, current_stat.st_gid)
        os.write(descriptor, merged)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    candidate_stat = os.stat(swap_path, follow_symlinks=False)
    candidate_digest = hashlib.sha256(merged).hexdigest()
    journal_update(
        SWAP_PHASE="candidate-ready", SWAP_INTENT=intent,
        SWAP_BASIS_DEVICE=current_stat.st_dev,
        SWAP_BASIS_INODE=current_stat.st_ino,
        SWAP_BASIS_DIGEST=hashlib.sha256(current_data).hexdigest(),
        SWAP_CANDIDATE_DEVICE=candidate_stat.st_dev,
        SWAP_CANDIDATE_INODE=candidate_stat.st_ino,
        SWAP_CANDIDATE_DIGEST=candidate_digest,
        SWAP_DISPLACED_DEVICE=None, SWAP_DISPLACED_INODE=None,
        SWAP_DISPLACED_DIGEST=None, SWAP_FRESH_DEVICE=None,
        SWAP_FRESH_INODE=None, SWAP_FRESH_DIGEST=None,
        SWAP_FRESH_LOCATION=None)

    hook = os.environ.get("VX_HARBOR_TEST_BEFORE_EXCHANGE_HOOK")
    if hook and not globals().get("_hook_ran", False):
        globals()["_hook_ran"] = True
        if os.spawnv(os.P_WAIT, hook, [hook, current_path]) != 0:
            raise SystemExit(1)

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                          ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    if renameat2(-100, os.fsencode(swap_path), -100, os.fsencode(current_path), 2) != 0:
        raise OSError(ctypes.get_errno(), "renameat2 exchange failed")
    fsync_directories()
    displaced_data, displaced_stat = read_regular(swap_path)
    journal_update(
        SWAP_PHASE="exchanged",
        SWAP_DISPLACED_DEVICE=displaced_stat.st_dev,
        SWAP_DISPLACED_INODE=displaced_stat.st_ino,
        SWAP_DISPLACED_DIGEST=hashlib.sha256(displaced_data).hexdigest())
    hook = os.environ.get("VX_HARBOR_TEST_AFTER_EXCHANGE_HOOK")
    if hook and not globals().get("_after_hook_ran", False):
        globals()["_after_hook_ran"] = True
        if os.spawnv(os.P_WAIT, hook, [hook, current_path]) != 0:
            raise SystemExit(1)
    pathname_data, pathname_stat = read_regular(current_path)
    candidate_identity = (candidate_stat.st_dev, candidate_stat.st_ino)
    pathname_identity = (pathname_stat.st_dev, pathname_stat.st_ino)
    if pathname_identity != candidate_identity \
            or hashlib.sha256(pathname_data).hexdigest() != candidate_digest:
        journal_update(
            SWAP_PHASE="superseded", SWAP_FRESH_LOCATION="current",
            SWAP_FRESH_DEVICE=pathname_stat.st_dev,
            SWAP_FRESH_INODE=pathname_stat.st_ino,
            SWAP_FRESH_DIGEST=hashlib.sha256(pathname_data).hexdigest())
        raise SystemExit(1)
    identity = (current_stat.st_dev, current_stat.st_ino,
                current_stat.st_size, current_stat.st_mtime_ns)
    displaced_identity = (displaced_stat.st_dev, displaced_stat.st_ino,
                          displaced_stat.st_size, displaced_stat.st_mtime_ns)
    if displaced_identity != identity or displaced_data != current_data:
        raise SystemExit(1)
    journal_update(SWAP_PHASE="none", SWAP_INTENT=None)
    os.unlink(swap_path)
    fsync_directories()
    print(candidate_digest)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

_vx_harbor_transition_exchange() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

left, right = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                      ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, os.fsencode(left), -100, os.fsencode(right), 2) != 0:
    raise OSError(ctypes.get_errno(), "renameat2 exchange failed")
for directory in {os.path.dirname(left), os.path.dirname(right)}:
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

_vx_harbor_transition_swap_state_set() {
    local phase="$1" intent="$2" source
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" \
        || return 1
    if ! jq --arg phase "$phase" --arg intent "$intent" \
        '.SWAP_PHASE = $phase |
         .SWAP_INTENT = (if $intent == "none" then null else $intent end)' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

_vx_harbor_transition_identity() {
    stat -c '%d:%i' "$1"
}

_vx_harbor_transition_swap_exchanged_set() {
    local intent="$1" identity digest source
    identity="$(_vx_harbor_transition_identity \
        "$VX_HARBOR_TRANSITION_SWAP")" || return 1
    digest="$(sha256sum "$VX_HARBOR_TRANSITION_SWAP" | awk '{print $1}')" \
        || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" \
        || return 1
    if ! jq --arg intent "$intent" --arg identity "$identity" \
        --arg digest "$digest" '
          ($identity | split(":")) as $parts |
          .SWAP_PHASE = "exchanged" | .SWAP_INTENT = $intent |
          .SWAP_DISPLACED_DEVICE = ($parts[0] | tonumber) |
          .SWAP_DISPLACED_INODE = ($parts[1] | tonumber) |
          .SWAP_DISPLACED_DIGEST = $digest' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

_vx_harbor_transition_swap_fresh_set() {
    local location="$1" path="$2" identity digest source
    identity="$(_vx_harbor_transition_identity "$path")" || return 1
    digest="$(sha256sum "$path" | awk '{print $1}')" || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" \
        || return 1
    if ! jq --arg location "$location" --arg identity "$identity" \
        --arg digest "$digest" '
          ($identity | split(":")) as $parts |
          .SWAP_PHASE = "superseded" |
          .SWAP_FRESH_LOCATION = $location |
          .SWAP_FRESH_DEVICE = ($parts[0] | tonumber) |
          .SWAP_FRESH_INODE = ($parts[1] | tonumber) |
          .SWAP_FRESH_DIGEST = $digest' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

_vx_harbor_transition_swap_recover() {
    local current="$1" phase intent candidate_identity
    local current_identity swap_identity displaced_identity directory
    local fresh_location fresh_identity expected_current_identity
    phase="$(jq -er '.SWAP_PHASE' "$VX_HARBOR_TRANSITION_JOURNAL")" \
        || return 1
    intent="$(jq -r '.SWAP_INTENT // "none"' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    candidate_identity="$(jq -r '
        if .SWAP_CANDIDATE_DEVICE == null then ""
        else ((.SWAP_CANDIDATE_DEVICE|tostring) + ":" +
              (.SWAP_CANDIDATE_INODE|tostring)) end' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    displaced_identity="$(jq -r '
        if .SWAP_DISPLACED_DEVICE == null then ""
        else ((.SWAP_DISPLACED_DEVICE|tostring) + ":" +
              (.SWAP_DISPLACED_INODE|tostring)) end' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    current_identity="$(_vx_harbor_transition_identity "$current")" || return 1
    directory="$(dirname -- "$VX_HARBOR_TRANSITION_SWAP")" || return 1

    if [[ "$phase" == none ]]; then
        if [[ -e "$VX_HARBOR_TRANSITION_SWAP" \
            || -L "$VX_HARBOR_TRANSITION_SWAP" ]]; then
            _vx_harbor_transition_swap_secure "$VX_HARBOR_TRANSITION_SWAP" \
                || return 1
            rm -f -- "$VX_HARBOR_TRANSITION_SWAP" || return 1
            _vx_harbor_fsync "$directory" || return 1
        fi
        return 0
    fi
    [[ -f "$VX_HARBOR_TRANSITION_SWAP" \
        && ! -L "$VX_HARBOR_TRANSITION_SWAP" ]] || return 1
    swap_identity="$(_vx_harbor_transition_identity \
        "$VX_HARBOR_TRANSITION_SWAP")" || return 1

    if [[ "$phase" == candidate-ready ]]; then
        if [[ "$swap_identity" == "$candidate_identity" ]]; then
            _vx_harbor_transition_swap_state_set none none || return 1
            rm -f -- "$VX_HARBOR_TRANSITION_SWAP" || return 1
            _vx_harbor_fsync "$directory"
            return
        fi
        [[ "$current_identity" == "$candidate_identity" ]] || return 1
        _vx_harbor_transition_swap_exchanged_set "$intent" || return 1
        displaced_identity="$swap_identity"
        phase=exchanged
    fi

    if [[ "$phase" == exchanged ]]; then
        if [[ "$current_identity" == "$candidate_identity" ]]; then
            [[ -n "$displaced_identity" \
                && "$swap_identity" == "$displaced_identity" ]] || return 1
            _vx_harbor_transition_exchange \
                "$VX_HARBOR_TRANSITION_SWAP" "$current" || return 1
            swap_identity="$(_vx_harbor_transition_identity \
                "$VX_HARBOR_TRANSITION_SWAP")" || return 1
            if [[ "$swap_identity" != "$candidate_identity" ]]; then
                _vx_harbor_transition_swap_fresh_set swap \
                    "$VX_HARBOR_TRANSITION_SWAP" || return 1
                return 1
            fi
            _vx_harbor_transition_swap_state_set none none || return 1
            rm -f -- "$VX_HARBOR_TRANSITION_SWAP" || return 1
            _vx_harbor_fsync "$directory"
            return
        fi
        _vx_harbor_transition_swap_fresh_set current "$current" || return 1
        phase=superseded
    fi

    if [[ "$phase" == superseded ]]; then
        fresh_location="$(jq -er '.SWAP_FRESH_LOCATION' \
            "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
        fresh_identity="$(jq -r '
            ((.SWAP_FRESH_DEVICE|tostring) + ":" +
             (.SWAP_FRESH_INODE|tostring))' \
            "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
        if [[ "$fresh_location" == swap ]]; then
            [[ "$swap_identity" == "$fresh_identity" ]] || return 1
            expected_current_identity="$current_identity"
            _vx_harbor_transition_exchange \
                "$VX_HARBOR_TRANSITION_SWAP" "$current" || return 1
            current_identity="$(_vx_harbor_transition_identity "$current")" \
                || return 1
            swap_identity="$(_vx_harbor_transition_identity \
                "$VX_HARBOR_TRANSITION_SWAP")" || return 1
            [[ "$current_identity" == "$fresh_identity" ]] || return 1
            if [[ "$swap_identity" != "$expected_current_identity" ]]; then
                _vx_harbor_transition_swap_fresh_set swap \
                    "$VX_HARBOR_TRANSITION_SWAP" || return 1
                return 1
            fi
        else
            [[ "$current_identity" == "$fresh_identity" ]] || return 1
        fi
        [[ ! -e "$VX_HARBOR_TRANSITION_STALE" \
            && ! -L "$VX_HARBOR_TRANSITION_STALE" ]] || return 1
        mv -T -- "$VX_HARBOR_TRANSITION_SWAP" "$VX_HARBOR_TRANSITION_STALE" \
            || return 1
        _vx_harbor_fsync "$directory" || return 1
        _vx_harbor_transition_swap_state_set none none
    fi
}

_vx_harbor_transition_swap_secure() {
    local path="$1" expected_uid expected_gid
    [[ -f "$path" && ! -L "$path" ]] || return 1
    expected_uid="$(_vx_harbor_authority_uid)" || return 1
    expected_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ "$(stat -c '%u:%g:%h' "$path")" \
        == "$expected_uid:$expected_gid:1" ]]
}

_vx_harbor_transition_access_restore() {
    local owner="$1" old_shell="$2" group_member="$3" deny_present="$4" path
    _vx_harbor_transition_shell_set "$owner" "$old_shell" || return 1
    if [[ "$group_member" == true ]]; then
        /usr/bin/getent group "$VX_COMPOSE_SHELL_GROUP" >/dev/null 2>&1 || return 1
        /usr/sbin/usermod -a -G "$VX_COMPOSE_SHELL_GROUP" -- "$owner" \
            >/dev/null 2>&1 || return 1
    else
        vx_compose_shell_group_revoke "$owner" || return 1
    fi
    if [[ "$deny_present" == true ]]; then
        vx_compose_shell_access_deny_establish "$owner" || return 1
    else
        path="$(vx_compose_shell_access_deny_path "$owner")" || return 1
        [[ ! -L "$path" ]] || return 1
        rm -f -- "$path" || return 1
    fi
}

_vx_harbor_transition_shell_set() {
    /usr/bin/chsh -s "$2" "$1" >/dev/null 2>&1
}

_vx_harbor_transition_cleanup_files() {
    local directory
    directory="$(dirname -- "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    rm -f -- "$VX_HARBOR_TRANSITION_JOURNAL" || return 1
    _vx_harbor_fsync "$directory" || return 1
    rm -f -- "$VX_HARBOR_TRANSITION_SNAPSHOT" \
        "$VX_HARBOR_TRANSITION_AFTER" "$VX_HARBOR_TRANSITION_SWAP" \
        "$VX_HARBOR_TRANSITION_STALE" || return 1
    _vx_harbor_fsync "$directory"
}

vx_harbor_package_transition_recover() {
    local owner="$1" state mode old_quota generation observed_at operation_id
    local user_conf old_digest new_digest applied_digest current_digest current_device
    local old_shell group_member deny_present recorded_device
    _vx_harbor_transition_require_locks "$owner" || return 1
    _vx_harbor_transition_paths "$owner" || return 1
    if [[ ! -e "$VX_HARBOR_TRANSITION_JOURNAL" \
        && ! -L "$VX_HARBOR_TRANSITION_JOURNAL" ]]; then
        for orphan in "$VX_HARBOR_TRANSITION_SNAPSHOT" \
            "$VX_HARBOR_TRANSITION_AFTER" "$VX_HARBOR_TRANSITION_SWAP" \
            "$VX_HARBOR_TRANSITION_STALE"; do
            if [[ -e "$orphan" || -L "$orphan" ]]; then
                if [[ "$orphan" == "$VX_HARBOR_TRANSITION_SWAP" \
                    || "$orphan" == "$VX_HARBOR_TRANSITION_STALE" ]]; then
                    _vx_harbor_transition_swap_secure "$orphan" || return 1
                else
                    vx_harbor_secure_regular_file "$orphan" 0600 || return 1
                fi
                rm -f -- "$orphan" || return 1
            fi
        done
        if [[ -d "$(dirname -- "$VX_HARBOR_TRANSITION_SNAPSHOT")" ]]; then
            _vx_harbor_fsync "$(dirname -- "$VX_HARBOR_TRANSITION_SNAPSHOT")" \
                || return 1
        fi
        return 0
    fi
    _vx_harbor_transition_journal_validate \
        "$VX_HARBOR_TRANSITION_JOURNAL" || return 1
    vx_harbor_secure_regular_file "$VX_HARBOR_TRANSITION_SNAPSHOT" 0600 \
        || return 1
    vx_harbor_secure_regular_file "$VX_HARBOR_TRANSITION_AFTER" 0600 \
        || return 1
    state="$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    user_conf="$(jq -er '.USER_CONF_PATH' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$user_conf" == "$VESTA/data/users/$owner/user.conf" ]] || return 1
    old_digest="$(jq -er '.OLD_DIGEST' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    new_digest="$(jq -er '.NEW_DIGEST' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$(sha256sum "$VX_HARBOR_TRANSITION_SNAPSHOT" | awk '{print $1}')" \
        == "$old_digest" ]] || return 1
    current_digest="$(sha256sum "$user_conf" | awk '{print $1}')" || return 1
    recorded_device="$(jq -er '.USER_CONF_DEVICE' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    current_device="$(stat -c '%d' "$user_conf")" || return 1
    [[ "$current_device" == "$recorded_device" ]] || return 1
    _vx_harbor_transition_swap_recover "$user_conf" || return 1
    if [[ "$state" == committed || "$state" == access-completed ]]; then
        _vx_harbor_transition_user_conf_merge \
            "$user_conf" "$VX_HARBOR_TRANSITION_AFTER" \
            "$VX_HARBOR_TRANSITION_SWAP" commit >/dev/null || return 1
        _vx_harbor_transition_access_converge "$owner" || return 1
        _vx_harbor_transition_cleanup_files
        return
    fi
    mode="$(jq -er '.MODE' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    old_quota="$(jq -er '.OLD_QUOTA' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    generation="$(jq -er '.OBSERVATION_GENERATION // "disabled"' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    observed_at="$(jq -er '.OBSERVED_AT // "disabled"' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    operation_id="$(jq -er '.OPERATION_ID' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    if [[ "$mode" == managed ]]; then
        _vx_harbor_transition_quota_apply "$owner" "$old_quota" \
            "$generation" "$observed_at" "$operation_id" rollback || return 1
    fi
    if [[ "$state" == prepared ]]; then
        _vx_harbor_transition_cleanup_files
        return
    fi
    if [[ "$state" != prepared ]]; then
        _vx_harbor_transition_checkpoint recovery-before-user-conf || return 1
        current_digest="$(sha256sum "$user_conf" | awk '{print $1}')" || return 1
        applied_digest="$(jq -r '.APPLIED_DIGEST // empty' \
            "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
        if [[ "$current_digest" == "$old_digest" ]]; then
            :
        elif [[ "$current_digest" == "$new_digest" \
            || ( -n "$applied_digest" && "$current_digest" == "$applied_digest" ) ]]; then
            _vx_harbor_transition_user_conf_restore \
                "$user_conf" "$VX_HARBOR_TRANSITION_SNAPSHOT" || return 1
        else
            _vx_harbor_transition_user_conf_merge \
                "$user_conf" "$VX_HARBOR_TRANSITION_SNAPSHOT" \
                "$VX_HARBOR_TRANSITION_SWAP" rollback >/dev/null || return 1
        fi
    fi
    _vx_harbor_transition_trigger_compensate "$owner" || return 1
    _vx_harbor_transition_disk_quota_compensate "$owner" || return 1
    old_shell="$(jq -er '.OLD_SHELL' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    group_member="$(jq -r '.GROUP_MEMBER' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    deny_present="$(jq -r '.DENY_MARKER_PRESENT' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    _vx_harbor_transition_access_restore \
        "$owner" "$old_shell" "$group_member" "$deny_present" || return 1
    _vx_harbor_transition_cleanup_files
}

_vx_harbor_transition_disk_quota_restore() {
    [[ -n "${BIN:-}" && -x "$BIN/v-update-user-quota" ]] || return 1
    "$BIN/v-update-user-quota" "$1"
}

_vx_harbor_transition_disk_quota_compensate() {
    local owner="$1" pending compensated source
    pending="$(jq -r '.DISK_QUOTA_PENDING' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    compensated="$(jq -r '.DISK_QUOTA_COMPENSATED' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$pending" == true && "$compensated" == false ]] || return 0
    _vx_harbor_transition_disk_quota_restore "$owner" || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" \
        || return 1
    if ! jq '.DISK_QUOTA_COMPENSATED = true' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

_vx_harbor_transition_snapshot_value() {
    local key="$1" path="$2"
    sed -n "s/^${key}='\([^']*\)'$/\1/p" "$path" | head -n1
}

_vx_harbor_transition_trigger_compensate() {
    local owner="$1" pending compensated old_package trigger contact fname lname source
    pending="$(jq -r '.TRIGGER_PENDING' "$VX_HARBOR_TRANSITION_JOURNAL")" \
        || return 1
    compensated="$(jq -r '.TRIGGER_COMPENSATED' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$pending" == true && "$compensated" == false ]] || return 0
    old_package="$(jq -er '.OLD_PACKAGE' "$VX_HARBOR_TRANSITION_JOURNAL")" \
        || return 1
    trigger="$VESTA/data/packages/$old_package.sh"
    if [[ -e "$trigger" || -L "$trigger" ]]; then
        [[ -x "$trigger" && -f "$trigger" && ! -L "$trigger" ]] || return 1
        contact="$(_vx_harbor_transition_snapshot_value CONTACT \
            "$VX_HARBOR_TRANSITION_SNAPSHOT")" || return 1
        fname="$(_vx_harbor_transition_snapshot_value FNAME \
            "$VX_HARBOR_TRANSITION_SNAPSHOT")" || return 1
        lname="$(_vx_harbor_transition_snapshot_value LNAME \
            "$VX_HARBOR_TRANSITION_SNAPSHOT")" || return 1
        "$trigger" "$owner" "$contact" "$fname" "$lname" || return 1
    fi
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" \
        || return 1
    if ! jq '.TRIGGER_COMPENSATED = true' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_prepare() {
    local owner="$1" new_quota="$2" package="$3" staged_conf="$4"
    local old_shell="$5" group_member="$6" deny_present="$7"
    local mode old_quota observation used generation observed_at operation_id
    local created_at expires_at user_conf old_digest new_digest identity source token
    local snapshot_identity after_identity old_package
    _vx_harbor_transition_require_locks "$owner" || return 1
    [[ "$new_quota" == unlimited \
        || "$new_quota" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    [[ "$package" =~ ^[a-zA-Z0-9._-]+$ && -f "$staged_conf" \
        && ! -L "$staged_conf" && "$group_member" =~ ^(yes|no)$ \
        && "$deny_present" =~ ^(yes|no)$ && "$old_shell" == /* ]] || return 1
    vx_harbor_package_transition_recover "$owner" || return 1
    _vx_harbor_transition_paths "$owner" || return 1
    mode="$(vx_harbor_provider_mode)" || return 1
    if [[ "$mode" == managed ]]; then
        old_quota="$(_vx_harbor_current_owner_quota "$owner")" || return 1
        observation="$(_vx_harbor_observation_json "$owner")" || return 1
        used="$(jq -er '.USED_MB' <<<"$observation")" || return 1
        generation="$(jq -er '.GENERATION' <<<"$observation")" || return 1
        observed_at="$(jq -er '.OBSERVED_AT' <<<"$observation")" || return 1
        if [[ "$new_quota" != unlimited ]] && (( 10#$new_quota < 10#$used )); then
            return 1
        fi
    else
        old_quota=0
        generation=disabled
        observed_at=disabled
    fi
    user_conf="$VESTA/data/users/$owner/user.conf"
    [[ -f "$user_conf" && ! -L "$user_conf" ]] || return 1
    if declare -F vx_compose_shell_user_conf_secure >/dev/null; then
        vx_compose_shell_user_conf_secure "$owner" "$user_conf" || return 1
    fi
    [[ "$(stat -c '%u:%h' "$staged_conf")" \
        == "$(_vx_harbor_authority_uid):1" ]] || return 1
    operation_id="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')" || return 1
    [[ "$operation_id" =~ ^[a-f0-9]{32}$ ]] || return 1
    created_at="$(_vx_harbor_now_epoch)" || return 1
    expires_at=$((created_at + VX_HARBOR_TRANSITION_TTL_SECONDS))
    snapshot_identity="$(_vx_harbor_transition_snapshot_create \
        "$user_conf" "$VX_HARBOR_TRANSITION_SNAPSHOT")" || return 1
    identity="${snapshot_identity%:*}"
    old_digest="${snapshot_identity##*:}"
    after_identity="$(_vx_harbor_transition_snapshot_create \
        "$staged_conf" "$VX_HARBOR_TRANSITION_AFTER")" || {
        rm -f -- "$VX_HARBOR_TRANSITION_SNAPSHOT"
        return 1
    }
    new_digest="${after_identity##*:}"
    old_package="$(_vx_harbor_transition_snapshot_value PACKAGE \
        "$VX_HARBOR_TRANSITION_SNAPSHOT")" || return 1
    [[ "$old_package" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq -n --arg owner "$owner" --arg package "$package" \
        --arg path "$user_conf" --arg identity "$identity" \
        --arg old_digest "$old_digest" --arg new_digest "$new_digest" \
        --arg old_package "$old_package" \
        --arg old_quota "$old_quota" --arg new_quota "$new_quota" \
        --arg mode "$mode" --arg generation "$generation" \
        --arg observed_at "$observed_at" --arg operation_id "$operation_id" \
        --arg old_shell "$old_shell" --argjson created_at "$created_at" \
        --argjson expires_at "$expires_at" \
        --argjson group_member "$([[ "$group_member" == yes ]] && echo true || echo false)" \
        --argjson deny_present "$([[ "$deny_present" == yes ]] && echo true || echo false)" '
          ($identity | split(":")) as $identity_parts | {
            SCHEMA:1, STATE:"prepared", OPERATION_ID:$operation_id,
            APPLIED_DIGEST:null, ACCESS_COMPLETED:false,
            DISK_QUOTA_PENDING:false, DISK_QUOTA_COMPENSATED:false,
            TRIGGER_PENDING:false, TRIGGER_COMPENSATED:false,
            SWAP_PHASE:"none", SWAP_INTENT:null,
            SWAP_BASIS_DEVICE:null, SWAP_BASIS_INODE:null, SWAP_BASIS_DIGEST:null,
            SWAP_CANDIDATE_DEVICE:null, SWAP_CANDIDATE_INODE:null, SWAP_CANDIDATE_DIGEST:null,
            SWAP_DISPLACED_DEVICE:null, SWAP_DISPLACED_INODE:null, SWAP_DISPLACED_DIGEST:null,
            SWAP_FRESH_DEVICE:null, SWAP_FRESH_INODE:null, SWAP_FRESH_DIGEST:null,
            SWAP_FRESH_LOCATION:null,
            OWNER:$owner, PACKAGE:$package, USER_CONF_PATH:$path,
            OLD_PACKAGE:$old_package,
            USER_CONF_DEVICE:($identity_parts[0] | tonumber),
            USER_CONF_INODE:($identity_parts[1] | tonumber),
            OLD_DIGEST:$old_digest, NEW_DIGEST:$new_digest,
            OLD_QUOTA:(if $old_quota == "unlimited" then $old_quota else ($old_quota|tonumber) end),
            NEW_QUOTA:(if $new_quota == "unlimited" then $new_quota else ($new_quota|tonumber) end),
            MODE:$mode,
            OBSERVATION_GENERATION:(if $generation == "disabled" then null else $generation end),
            OBSERVED_AT:(if $observed_at == "disabled" then null else $observed_at end),
            OLD_SHELL:$old_shell, GROUP_MEMBER:$group_member,
            DENY_MARKER_PRESENT:$deny_present,
            CREATED_AT:$created_at, EXPIRES_AT:$expires_at
          }' >"$source" \
        || ! vx_harbor_json_write_atomic "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source" "$VX_HARBOR_TRANSITION_SNAPSHOT" \
            "$VX_HARBOR_TRANSITION_AFTER"
        return 1
    fi
    rm -f -- "$source"
    token="$(_vx_harbor_transition_token_create \
        "$owner" "$operation_id" "$expires_at" "$generation")" || return 1
    _vx_harbor_transition_checkpoint journal-written || return 1
    _vx_harbor_transition_user_conf_matches_capture "$user_conf" \
        "${identity%%:*}" "${identity##*:}" "$old_digest" || return 1
    if [[ "$mode" == managed ]]; then
        observation="$(_vx_harbor_observation_json "$owner")" || return 1
        [[ "$(jq -er '.GENERATION' <<<"$observation")" == "$generation" \
            && "$(jq -er '.OBSERVED_AT' <<<"$observation")" == "$observed_at" ]] \
            || return 1
        _vx_harbor_transition_quota_apply "$owner" "$new_quota" \
            "$generation" "$observed_at" "$operation_id" apply || return 1
        _vx_harbor_transition_checkpoint quota-mutated || return 1
    fi
    _vx_harbor_transition_journal_state_set quota-applied || return 1
    _vx_harbor_transition_checkpoint quota-recorded || return 1
    printf '%s\n' "$token"
}

_vx_harbor_transition_token_journal_require() {
    local owner="$1" token="$2" operation_id generation
    _vx_harbor_transition_token_read "$owner" "$token" || return 1
    _vx_harbor_transition_paths "$owner" || return 1
    _vx_harbor_transition_journal_validate "$VX_HARBOR_TRANSITION_JOURNAL" || return 1
    operation_id="$(jq -er '.OPERATION_ID' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    generation="$(jq -er '.OBSERVATION_GENERATION // "disabled"' \
        "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$operation_id" == "$VX_HARBOR_TRANSITION_OPERATION_ID" \
        && "$generation" == "$VX_HARBOR_TRANSITION_GENERATION" ]]
}

vx_harbor_package_transition_user_conf_applied() {
    local owner="$1" token="$2" path expected source
    _vx_harbor_transition_require_locks "$owner" || return 1
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == quota-applied ]] \
        || return 1
    path="$(jq -er '.USER_CONF_PATH' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    expected="$(jq -er '.NEW_DIGEST' "$VX_HARBOR_TRANSITION_JOURNAL")" || return 1
    [[ "$(sha256sum "$path" | awk '{print $1}')" == "$expected" ]] || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq --arg digest "$expected" \
        '.STATE = "user-conf-applied" | .APPLIED_DIGEST = $digest' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_user_conf_apply() {
    local owner="$1" token="$2" staged_conf="$3" digest source
    _vx_harbor_transition_require_locks "$owner" || return 1
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == quota-applied \
        && -f "$staged_conf" && ! -L "$staged_conf" ]] || return 1
    digest="$(_vx_harbor_transition_user_conf_merge \
        "$VESTA/data/users/$owner/user.conf" "$staged_conf" \
        "$VX_HARBOR_TRANSITION_SWAP" apply)" || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq --arg digest "$digest" \
        '.STATE = "user-conf-applied" | .APPLIED_DIGEST = $digest' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_disk_quota_pending() {
    local owner="$1" token="$2" source
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == user-conf-applied ]] \
        || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq '.DISK_QUOTA_PENDING = true | .DISK_QUOTA_COMPENSATED = false' \
        "$VX_HARBOR_TRANSITION_JOURNAL" \
        >"$source" || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_trigger_pending() {
    local owner="$1" token="$2" source
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == user-conf-applied ]] \
        || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq '.TRIGGER_PENDING = true | .TRIGGER_COMPENSATED = false' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_side_effects_applied() {
    local owner="$1" token="$2"
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == user-conf-applied ]] \
        || return 1
    _vx_harbor_transition_journal_state_set side-effects-applied
}

vx_harbor_package_transition_commit() {
    local owner="$1" token="$2"
    _vx_harbor_transition_require_locks "$owner" || return 1
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == side-effects-applied ]] \
        || return 1
    _vx_harbor_transition_journal_state_set committed || return 1
    _vx_harbor_transition_checkpoint committed || return 1
}

_vx_harbor_transition_access_converge() {
    local owner="$1" path
    if vx_compose_shell_should_be_group_member "$owner"; then
        vx_compose_shell_group_grant_if_eligible "$owner" || return 1
    else
        vx_compose_shell_group_revoke "$owner" || return 1
    fi
    path="$(vx_compose_shell_access_deny_path "$owner")" || return 1
    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" ]]; then
        [[ -f "$path" && "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]] \
            || return 1
        rm -f -- "$path" || return 1
    fi
}

vx_harbor_package_transition_access_complete() {
    local owner="$1" token="$2" source
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == committed ]] \
        || return 1
    _vx_harbor_transition_access_converge "$owner" || return 1
    _vx_harbor_transition_checkpoint access-converged || return 1
    source="$(mktemp "$(vx_harbor_root)/transactions/.journal.XXXXXX")" || return 1
    if ! jq '.STATE = "access-completed" | .ACCESS_COMPLETED = true' \
        "$VX_HARBOR_TRANSITION_JOURNAL" >"$source" \
        || ! vx_harbor_json_write_atomic \
            "$VX_HARBOR_TRANSITION_JOURNAL" "$source"; then
        rm -f -- "$source"
        return 1
    fi
    rm -f -- "$source"
}

vx_harbor_package_transition_finalize() {
    local owner="$1" token="$2"
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    [[ "$(jq -er '.STATE' "$VX_HARBOR_TRANSITION_JOURNAL")" == access-completed ]] \
        || return 1
    _vx_harbor_transition_cleanup_files
}

vx_harbor_package_transition_rollback() {
    local owner="$1" token="$2"
    _vx_harbor_transition_require_locks "$owner" || return 1
    _vx_harbor_transition_token_journal_require "$owner" "$token" || return 1
    vx_harbor_package_transition_recover "$owner"
}
