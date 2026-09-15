#!/usr/bin/env bash

vx_domain_connection_root() { printf '%s/data/vx/domain-connections\n' "$VESTA"; }
vx_domain_connection_hostname_root() { printf '%s/hostnames\n' "$(vx_domain_connection_root)"; }
vx_domain_connection_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
vx_domain_connection_error() { printf '%s\n' "domain-connection: $*" >&2; }

# Validate each existing ancestor before following it. Registry authority is root,
# never the invoking uid; sticky shared temporary roots are allowed for fixtures.
vx_domain_connection_safe_path() {
    /usr/bin/python3 - "$1" "${2:-directory}" <<'PYSAFE'
import os, stat, sys
path=os.path.abspath(sys.argv[1]); kind=sys.argv[2]
parts=path.split('/'); current='/'
for part in parts[1:]:
    current=os.path.join(current,part)
    try: st=os.lstat(current)
    except FileNotFoundError: raise SystemExit(1)
    last=current==path
    if st.st_uid!=0 or stat.S_ISLNK(st.st_mode): raise SystemExit(1)
    if last and kind=='file':
        if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode)!=0o600 or st.st_nlink!=1: raise SystemExit(1)
    elif not stat.S_ISDIR(st.st_mode) or (st.st_mode & 0o022 and not st.st_mode & stat.S_ISVTX): raise SystemExit(1)
PYSAFE
}

vx_domain_connection_prepare() {
    local path root
    [[ $EUID == 0 ]] || return 1
    vx_domain_connection_safe_path "$VESTA/data" || return 1
    for path in "$VESTA/data/vx" "$(vx_domain_connection_root)" "$(vx_domain_connection_hostname_root)"; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then (umask 077; mkdir "$path") || return 1; fi
        vx_domain_connection_safe_path "$path" || return 1
    done
    root=$(vx_domain_connection_root)
    [[ $(stat -c %a "$root") == 700 && $(stat -c %a "$root/hostnames") == 700 ]] || return 1
    if [[ ! -e "$root/config.json" && ! -L "$root/config.json" ]]; then
        (umask 077; set -o noclobber; printf '%s\n' '{"VERSION":1,"ENROLLMENT":"disabled","CONNECTION_LIMIT":0}' >"$root/config.json") 2>/dev/null || :
    fi
    vx_domain_connection_safe_path "$root/config.json" file
}

vx_domain_connection_open_lock() {
    local lock=$1 descriptor=$2
    vx_domain_connection_safe_path "${lock%/*}" || return 1
    if [[ ! -e "$lock" && ! -L "$lock" ]]; then (umask 077; set -o noclobber; : >"$lock") 2>/dev/null || :; fi
    vx_domain_connection_safe_path "$lock" file || return 1
    # Parent directories are root-only; validation and open cannot race a tenant.
    exec {descriptor}<>"$lock" || return 1
    /usr/bin/flock -w 2 -x "$descriptor" || { eval "exec ${descriptor}>&-"; return 1; }
    printf -v "$2" '%s' "$descriptor"
}
vx_domain_connection_owner_lock() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || return 1
    vx_domain_connection_open_lock "$(vx_domain_connection_root)/.$1.lock" VX_DOMAIN_CONNECTION_OWNER_LOCK_FD
}
vx_domain_connection_owner_unlock() {
    [[ -n "${VX_DOMAIN_CONNECTION_OWNER_LOCK_FD:-}" ]] || return 0
    /usr/bin/flock -u "$VX_DOMAIN_CONNECTION_OWNER_LOCK_FD"; eval "exec ${VX_DOMAIN_CONNECTION_OWNER_LOCK_FD}>&-"; unset VX_DOMAIN_CONNECTION_OWNER_LOCK_FD
}

vx_domain_connection_canonical_hostname() {
    local input="$1"
    /usr/bin/python3 - "$input" <<'PY'
import ipaddress, sys
import idna
s=sys.argv[1].strip()
if s.endswith('.'): s=s[:-1]
if not s or '://' in s or '/' in s or ':' in s or '*' in s: raise SystemExit(1)
try: ipaddress.ip_address(s); raise SystemExit(1)
except ValueError: pass
try: h=idna.encode(s, uts46=True, std3_rules=True).decode().lower()
except idna.IDNAError: raise SystemExit(1)
if len(h)>253 or any(len(x)>63 for x in h.split('.')) or '.' not in h: raise SystemExit(1)
print(h)
PY
}

vx_domain_connection_hostname_valid() {
    local hostname="$1"
    [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
    [[ -n "$(vx_domain_connection_psl_registrable_domain "$hostname")" ]] || return 1
    ! vx_domain_connection_psl_public_suffix "$hostname" || return 1
    case "$hostname" in localhost|*.localhost|*.local|*.internal|*.test|*.example|*.invalid) return 1;; esac
}

# libpsl is the maintained platform PSL authority.  The CLI is not installed
# on every supported host, so bind the installed shared library directly.
vx_domain_connection_psl_public_suffix() {
    /usr/bin/python3 - "$1" <<'PY'
import ctypes, sys
lib = ctypes.CDLL('libpsl.so.5')
lib.psl_builtin.restype = ctypes.c_void_p
lib.psl_is_public_suffix.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
lib.psl_is_public_suffix.restype = ctypes.c_int
raise SystemExit(0 if lib.psl_is_public_suffix(lib.psl_builtin(), sys.argv[1].encode()) else 1)
PY
}
vx_domain_connection_psl_registrable_domain() {
    /usr/bin/python3 - "$1" <<'PY'
import ctypes, sys
lib = ctypes.CDLL('libpsl.so.5')
lib.psl_builtin.restype = ctypes.c_void_p
lib.psl_registrable_domain.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
lib.psl_registrable_domain.restype = ctypes.c_char_p
result = lib.psl_registrable_domain(lib.psl_builtin(), sys.argv[1].encode())
if not result: raise SystemExit(1)
print(result.decode())
PY
}

vx_domain_connection_hash() { printf '%s' "$1" | /usr/bin/sha256sum | /usr/bin/awk '{print $1}'; }
vx_domain_connection_record_path() { printf '%s/%s.json\n' "$(vx_domain_connection_hostname_root)" "$(vx_domain_connection_hash "$1")"; }

vx_domain_connection_record_read() {
    local hostname="$1" path
    path="$(vx_domain_connection_record_path "$hostname")"
    vx_domain_connection_safe_path "$path" file || return 1
    [[ "$(stat -c %a "$(vx_domain_connection_root)")" == 700 && "$(stat -c %a "$(vx_domain_connection_hostname_root)")" == 700 ]] || return 1
    /usr/bin/jq -ce --arg hostname "$hostname" 'select(.HOSTNAME == $hostname and (.VERSION == 1))' "$path"
}

vx_domain_connection_is_apex() {
    local hostname="$1" registrable
    registrable="$(vx_domain_connection_psl_registrable_domain "$hostname")" || return 1
    [[ "$hostname" == "$registrable" ]]
}

# Flush intent before external mutation, including the directory entry rename.
vx_domain_connection_atomic_replace() {
    /usr/bin/python3 - "$1" "$2" <<'PYATOMIC'
import os, sys
source, target=sys.argv[1:]
fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
try: os.fsync(fd)
finally: os.close(fd)
os.replace(source,target)
fd=os.open(os.path.dirname(target),os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try: os.fsync(fd)
finally: os.close(fd)
PYATOMIC
}

vx_domain_connection_record_write() {
    local hostname="$1" payload="$2" path temp
    path="$(vx_domain_connection_record_path "$hostname")"
    vx_domain_connection_safe_path "${path%/*}" || return 1
    [[ $(stat -c %a "$(vx_domain_connection_root)") == 700 && $(stat -c %a "${path%/*}") == 700 ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then vx_domain_connection_safe_path "$path" file || return 1; fi
    /usr/bin/jq -e --arg hostname "$hostname" '.HOSTNAME == $hostname and (.VERSION == 1)' >/dev/null <<<"$payload" || return 1
    temp="$(/usr/bin/mktemp "$(vx_domain_connection_hostname_root)/.record.XXXXXX")" || return 1
    umask 077; printf '%s\n' "$payload" | /usr/bin/jq -S . >"$temp" || { rm -f -- "$temp"; return 1; }
    chmod 0600 "$temp" && vx_domain_connection_atomic_replace "$temp" "$path"
}

vx_domain_connection_lock() {
    vx_domain_connection_open_lock "$(vx_domain_connection_hostname_root)/.$(vx_domain_connection_hash "$1").lock" VX_DOMAIN_CONNECTION_LOCK_FD
}
vx_domain_connection_unlock() {
    [[ -n "${VX_DOMAIN_CONNECTION_LOCK_FD:-}" ]] || return 0
    /usr/bin/flock -u "$VX_DOMAIN_CONNECTION_LOCK_FD"; eval "exec ${VX_DOMAIN_CONNECTION_LOCK_FD}>&-"; unset VX_DOMAIN_CONNECTION_LOCK_FD
}

vx_domain_connection_capability_json() {
    local enrollment target='{}'
    if vx_domain_connection_safe_path "$(vx_domain_connection_root)/config.json" file; then enrollment="$(/usr/bin/jq -r '.ENROLLMENT // "disabled"' "$(vx_domain_connection_root)/config.json")"; else enrollment=disabled; fi
    target="$(vx_domain_connection_target_read_json 2>/dev/null)" || target='{}'
    /usr/bin/jq -cn --arg enrollment "$enrollment" --argjson target "$target" '{version:1,capabilities:{enrollmentEnabled:($enrollment == "enabled"),connectionTarget:($target.TARGET_FQDN // null),ingress:{ipv4:([($target.IPV4 // empty)]|map(select(type=="string" and length>0))),ipv6:([($target.IPV6 // empty)]|map(select(type=="string" and length>0))),supportsApex:(($target.IPV4 // "")|length>0)},supportedStates:["pending_verification","pending_dns","pending_tls","connected","degraded","disconnecting","disconnected","failed","recovery_required"]}}'
}

vx_domain_connection_public_json() {
    local record="$1" quota_used="${2:-}" quota_available="${3:-}" instructions quota target='{}' hostname apex
    if [[ -z "$quota_used" ]]; then quota="$(vx_domain_connection_quota_json "$(/usr/bin/jq -r .OWNER <<<"$record")")"; quota_used="$(/usr/bin/jq -r .used <<<"$quota")"; quota_available="$(/usr/bin/jq -r '.available // "null"' <<<"$quota")"; fi
    target="$(vx_domain_connection_target_read_json 2>/dev/null)" || target='{}'
    hostname="$(/usr/bin/jq -r .HOSTNAME <<<"$record")"; apex=false; vx_domain_connection_is_apex "$hostname" && apex=true
    instructions="$(/usr/bin/jq -cn --arg hostname "$hostname" --arg token "$(/usr/bin/jq -r .PROOF_TOKEN <<<"$record")" --arg target "$(/usr/bin/jq -r '.TARGET_FQDN // empty' <<<"$target")" --arg ipv4 "$(/usr/bin/jq -r '.IPV4 // empty' <<<"$target")" --argjson apex "$apex" '[{recordType:"TXT",name:("_vx-verify."+$hostname),value:$token}] + if $target == "" then [] elif $apex and $ipv4 != "" then [{recordType:"A",name:"@",value:$ipv4}] else [{recordType:"CNAME",name:$hostname,value:$target}] end')"
    /usr/bin/jq -cn --argjson record "$record" --argjson instructions "$instructions" --argjson used "$quota_used" --argjson available "$quota_available" '{version:1,connection:{connectionID:$record.CONNECTION_ID,technicalFQDN:$record.TECHNICAL_FQDN,hostname:$record.HOSTNAME,generation:$record.GENERATION,state:$record.STATE,reason:$record.REASON,proof:{recordName:("_vx-verify."+$record.HOSTNAME),recordType:"TXT",recordValue:$record.PROOF_TOKEN,expiresAt:$record.PROOF_EXPIRES_AT},instructions:$instructions,lastCheckedAt:$record.LAST_CHECKED_AT,lastSuccessfulAt:$record.LAST_SUCCESSFUL_AT,nextCheckAt:$record.NEXT_CHECK_AT,observations:($record.OBSERVATIONS + (if $record.RENEWAL then {renewal:$record.RENEWAL} else {} end))},quota:{used:$used,available:$available}}'
}

vx_domain_connection_is_native_child() {
    local owner="$1" hostname="$2" record
    record="$(vx_domain_connection_record_read "$hostname")" || return 1
    /usr/bin/jq -e --arg owner "$owner" '.OWNER == $owner and (.STATE != "disconnected")' >/dev/null <<<"$record"
}

vx_domain_connection_authorize_native_tls() {
    local owner="$1" hostname="$2" id="$3" generation="$4" record
    record="$(vx_domain_connection_record_read "$hostname")" || return 1
    /usr/bin/jq -e --arg owner "$owner" --arg id "$id" --argjson generation "$generation" '.OWNER==$owner and .CONNECTION_ID==$id and .GENERATION==$generation and (.STATE=="pending_tls" or .STATE=="degraded" or .STATE=="connected")' >/dev/null <<<"$record"
}

vx_domain_connection_native_renewal_record() {
    local owner="$1" hostname="$2" record
    record="$(vx_domain_connection_record_read "$hostname")" || return 1
    /usr/bin/jq -e --arg owner "$owner" '.OWNER==$owner and (.STATE=="connected" or .STATE=="degraded")' >/dev/null <<<"$record" || return 1
    VX_DOMAIN_CONNECTION_RECORD="$(vx_domain_connection_record_path "$hostname")"
    export VX_DOMAIN_CONNECTION_RECORD VX_DOMAIN_CONNECTION_NATIVE_TLS=1
}

vx_domain_connection_enrollment_enabled() {
    local enrollment
    vx_domain_connection_safe_path "$(vx_domain_connection_root)/config.json" file || return 2
    enrollment=$(/usr/bin/jq -er '.ENROLLMENT // "disabled"' "$(vx_domain_connection_root)/config.json") || return 2
    [[ "$enrollment" == enabled || "$enrollment" == disabled ]] || return 2
    [[ "$enrollment" == enabled ]]
}

# All scans use the same protected read path, including read-only public lists.
vx_domain_connection_records() {
    local path hostname
    [[ -d "$(vx_domain_connection_hostname_root)" ]] || return 0
    vx_domain_connection_safe_path "$(vx_domain_connection_hostname_root)" || return 1
    for path in "$(vx_domain_connection_hostname_root)"/*.json; do
        [[ -e "$path" || -L "$path" ]] || continue
        vx_domain_connection_safe_path "$path" file || return 1
        hostname=$(jq -er '.HOSTNAME' "$path") || return 1
        [[ "$path" == "$(vx_domain_connection_record_path "$hostname")" ]] || return 1
        vx_domain_connection_record_read "$hostname" || return 1
    done
}

vx_domain_connection_quota_json() {
    local owner=$1 records
    [[ "$owner" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || return 1
    records=$(vx_domain_connection_records) || return 1
    /usr/bin/python3 - "$VESTA/data/users/$owner" "$owner" "$(vx_domain_connection_root)/config.json" "$records" <<'PYQUOTA'
import json,pathlib,re,sys
root=pathlib.Path(sys.argv[1]); owner=sys.argv[2]
config=json.loads(pathlib.Path(sys.argv[3]).read_text()) if pathlib.Path(sys.argv[3]).exists() else {}
rows=(root/'web.conf').read_text().splitlines(); user=(root/'user.conf').read_text()
match=re.search(r"(?:^|\s)WEB_DOMAINS='([^']*)'",user)
if not match: raise SystemExit(1)
limit=match[1]
if limit!='unlimited' and not limit.isdigit(): raise SystemExit(1)
native={m[1] for row in rows if (m:=re.match(r"DOMAIN='([^']+)'",row))}
records=[json.loads(line) for line in sys.argv[4].splitlines()]
active=[r for r in records if r['OWNER']==owner and not r.get('RESERVATION_RELEASED',False) and r['STATE']!='disconnected']
used=sum(bool(re.match(r"DOMAIN='[^']+'",row)) for row in rows)+sum(r['HOSTNAME'] not in native for r in active)
available=None if limit=='unlimited' else max(0,int(limit)-used)
connection_limit=int(config.get('CONNECTION_LIMIT',0))
if connection_limit: available=min(available if available is not None else connection_limit,max(0,connection_limit-len(active)))
print(json.dumps({'used':used,'available':available}))
PYQUOTA
}
vx_domain_connection_quota_ok() {
    local quota
    quota=$(vx_domain_connection_quota_json "$1") || return 2
    jq -e '.available==null or .available>0' >/dev/null <<<"$quota"
}

vx_domain_connection_create() {
    local owner="$1" technical="$2" supplied_hostname="$3" request_id="$4" hostname path record id token now expires native_rc generation=1 target
    vx_domain_connection_prepare || return 1
    [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ && "$request_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$ ]] || return 2
    hostname="$(vx_domain_connection_canonical_hostname "$supplied_hostname")" || { vx_domain_connection_error 'invalid hostname'; return 2; }
    vx_domain_connection_hostname_valid "$hostname" || { vx_domain_connection_error 'unsupported public hostname'; return 2; }
    technical="$(vx_domain_connection_canonical_hostname "$technical")" || return 2
    vx_domain_connection_owner_lock "$owner" || return 1
    vx_domain_connection_lock "$hostname" || { vx_domain_connection_owner_unlock; return 1; }
    path="$(vx_domain_connection_record_path "$hostname")"
    if [[ -e "$path" || -L "$path" ]]; then
        record="$(vx_domain_connection_record_read "$hostname")" || { vx_domain_connection_unlock; vx_domain_connection_owner_unlock; return 1; }
        if /usr/bin/jq -e --arg owner "$owner" --arg technical "$technical" --arg request "$request_id" '.OWNER==$owner and .TECHNICAL_FQDN==$technical and .REQUEST_ID==$request' >/dev/null <<<"$record"; then printf '%s\n' "$record"; vx_domain_connection_unlock; vx_domain_connection_owner_unlock; return 0; fi
        if ! jq -e '.STATE=="disconnected" or (.STATE=="failed" and .RESERVATION_RELEASED==true and .CLEANUP.NATIVE_CHILD==false)' >/dev/null <<<"$record"; then
            vx_domain_connection_unlock; vx_domain_connection_owner_unlock; vx_domain_connection_error 'hostname is already reserved'; return 10
        fi
        generation=$(jq -r '.GENERATION+1' <<<"$record")
    fi
    native_rc=0; vx_domain_connection_enrollment_enabled || native_rc=$?
    if (( native_rc != 0 )); then
        vx_domain_connection_unlock; vx_domain_connection_owner_unlock; vx_domain_connection_error 'enrollment is disabled'
        (( native_rc == 1 )) && return 12
        return 14 # Unknown enrollment state; retain legacy CLI status without classifying it.
    fi
    VX_DC_OWNER="$owner" VX_DC_TECHNICAL_FQDN="$technical" vx_domain_connection_native_parent_binding || { vx_domain_connection_unlock; vx_domain_connection_owner_unlock; vx_domain_connection_error 'technical parent is not an authoritative managed binding'; return 1; }
    target=$(vx_domain_connection_target_read_json 2>/dev/null) || target='{}'
    if [[ "$hostname" == "$(jq -r '.TARGET_FQDN // empty' <<<"$target")" || ( -n "${VX_CF_ZONE_NAME:-}" && "$hostname" =~ ^s-[a-f0-9]{10}\. && "${hostname#*.}" == "$VX_CF_ZONE_NAME" ) ]]; then
        vx_domain_connection_unlock; vx_domain_connection_owner_unlock; vx_domain_connection_error 'platform hostname is reserved'; return 10
    fi
    native_rc=0; vx_domain_connection_native_hostname_in_use "$hostname" || native_rc=$?
    if (( native_rc != 0 )); then vx_domain_connection_unlock; vx_domain_connection_owner_unlock; return "$native_rc"; fi
    native_rc=0; vx_domain_connection_quota_ok "$owner" || native_rc=$?
    if (( native_rc != 0 )); then
        vx_domain_connection_unlock; vx_domain_connection_owner_unlock; vx_domain_connection_error 'connection quota exceeded'
        (( native_rc == 1 )) && return 11
        return 13 # Unknown quota state; retain legacy CLI status without classifying it.
    fi
    id="$(/usr/bin/head -c 32 /dev/urandom | /usr/bin/sha256sum | /usr/bin/cut -c1-32)"; token="$(/usr/bin/head -c 32 /dev/urandom | /usr/bin/sha256sum | /usr/bin/cut -c1-48)"
    now="$(vx_domain_connection_now)"; expires="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)"
    record="$(/usr/bin/jq -cn --arg owner "$owner" --arg technical "$technical" --arg hostname "$hostname" --arg request "$request_id" --arg id "$id" --arg token "$token" --arg now "$now" --arg expires "$expires" --argjson generation "$generation" '{VERSION:1,OWNER:$owner,TECHNICAL_FQDN:$technical,HOSTNAME:$hostname,REQUEST_ID:$request,CONNECTION_ID:$id,GENERATION:$generation,PROOF_TOKEN:$token,PROOF_EXPIRES_AT:$expires,STATE:"pending_verification",REASON:"awaiting_txt_proof",CREATED_AT:$now,LAST_CHECKED_AT:null,LAST_SUCCESSFUL_AT:null,NEXT_CHECK_AT:$now,OBSERVATIONS:{},CLEANUP:{NATIVE_CHILD:false}}')"
    vx_domain_connection_record_write "$hostname" "$record" || { vx_domain_connection_unlock; vx_domain_connection_owner_unlock; return 1; }; printf '%s\n' "$record"; vx_domain_connection_unlock; vx_domain_connection_owner_unlock
}

vx_domain_connection_list() {
    local records
    records=$(vx_domain_connection_records) || return 1
    jq -cs --arg owner "$1" --arg technical "$2" '[.[] | select(.OWNER==$owner and .TECHNICAL_FQDN==$technical)] | sort_by(.CREATED_AT)' <<<"$records"
}

vx_domain_connection_find_id() {
    local records
    records=$(vx_domain_connection_list "$1" "$2") || return 1
    jq -ce --arg id "$3" '.[] | select(.CONNECTION_ID==$id)' <<<"$records"
}

vx_domain_connection_disconnect() (
    local owner="$1" technical="$2" id="$3" record hostname updated now
    vx_domain_connection_owner_lock "$owner" || return 1
    record="$(vx_domain_connection_find_id "$owner" "$technical" "$id")" || return 2
    hostname="$(jq -r .HOSTNAME <<<"$record")"
    vx_domain_connection_lock "$hostname" || return 1
    record="$(vx_domain_connection_record_read "$hostname")" || return 1
    jq -e --arg owner "$owner" --arg technical "$technical" --arg id "$id" '.OWNER==$owner and .TECHNICAL_FQDN==$technical and .CONNECTION_ID==$id' >/dev/null <<<"$record" || return 9
    if jq -e '.STATE=="disconnecting" or .STATE=="disconnected"' >/dev/null <<<"$record"; then printf '%s\n' "$record"; return 0; fi
    now="$(vx_domain_connection_now)"
    updated="$(jq --arg now "$now" '.CLEANUP.NATIVE_GENERATION=(.CLEANUP.NATIVE_GENERATION // .GENERATION) | .GENERATION += (if .OPERATION.KIND=="cleanup" then 0 else 1 end) | .STATE="disconnecting" | .REASON="cleanup_requested" | .NEXT_CHECK_AT=$now | .OPERATION={KIND:"cleanup",GENERATION:.GENERATION,STARTED_AT:$now}' <<<"$record")"
    vx_domain_connection_record_write "$hostname" "$updated" || return 1
    printf '%s\n' "$updated"
)
