#!/usr/bin/env bash

VX_HARBOR_RESTORE_APPLY_DEFERRED=78

vx_harbor_backup_layout_root() { printf '%s\n' "${VX_HARBOR_BACKUP_LAYOUT_ROOT:-$VESTA/data/backup/harbor}"; }
_vx_harbor_service_is_active() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-active vesta-harbor.service >/dev/null 2>&1; }
_vx_harbor_service_stop() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service; }
_vx_harbor_service_start() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service; }
_vx_harbor_age() { printf '%s\n' "${VX_HARBOR_AGE:-/usr/bin/age}"; }

_vx_harbor_cleanup_stage() {
    if [[ -n "${VX_HARBOR_CLEANUP_STAGE:-}" ]]; then
        [[ "$VX_HARBOR_CLEANUP_STAGE" == "$(vx_harbor_root)"/.backup-stage.* || "$VX_HARBOR_CLEANUP_STAGE" == "$(vx_harbor_root)"/.restore-validate.* ]] || return 1
        /usr/bin/rm -rf -- "$VX_HARBOR_CLEANUP_STAGE"
    fi
    unset VX_HARBOR_CLEANUP_STAGE
}

_vx_harbor_backup_stage() {
    local stage="$1" recipient="$2" root data secret_list secret_tar secret_cipher
    root="$(vx_harbor_root)"; data="$(vx_harbor_data_root)"
    [[ -d "$data" && ! -L "$data" ]] || return 1
    /usr/bin/mkdir -m 0700 -p "$stage/payload" "$stage/secret-source" || return 1
    # Build only the fixed recovery inventory. No source tree is recursively
    # copied until Python has matched it to an allowlisted authority/data class.
    /usr/bin/python3 - "$root" "$data" "$stage/payload" "$stage/secret-source" <<'PY' || return 1
import json, os, pathlib, re, shutil, stat, sys
root, data, payload, secrets = map(pathlib.Path, sys.argv[1:])

def regular(path):
    value=os.lstat(path)
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise SystemExit(1)
    return value

def copy(source, relative, destination_root=payload):
    value=regular(source)
    target=destination_root/relative
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(source, target, follow_symlinks=False)
    os.chmod(target, stat.S_IMODE(value.st_mode))
    try: os.chown(target, value.st_uid, value.st_gid)
    except PermissionError:
        if (value.st_uid, value.st_gid) != (os.getuid(), os.getgid()): raise

def json_value(path):
    regular(path)
    value=json.loads(path.read_text())
    if not isinstance(value, dict): raise SystemExit(1)
    return value

provider=json_value(root/'provider.json')
if set(provider) != {'SCHEMA','MODE','PINNED_VERSION','RUNNING_VERSION','INSTALLATION_ID','ORIGIN','RELEASE_MANIFEST_SHA256','LAST_HEALTH_AT','LAST_BACKUP_ID','LAST_RESTORE_TEST_AT','LAST_UPGRADE'} or provider['SCHEMA'] != 1 or provider['PINNED_VERSION'] != 'v2.15.0': raise SystemExit(1)
copy(root/'provider.json', 'authority/provider.json')
copy(root/'backup-recipient.txt', 'authority/backup-recipient.txt')

authority_patterns={
 'owners': re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}\.json$'),
 'observations': re.compile(r'^(provider|provider-detail|[a-z0-9][a-z0-9_-]{0,31})\.json$'),
 'operations': re.compile(r'^(provider-disable|[a-z0-9][a-z0-9_-]{0,31})\.json$'),
 'rotations': re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}-(runtime|publisher)\.json$'),
 'tombstones': re.compile(r'^[a-z0-9][a-z0-9_-]{0,31}\.json$'),
 'backups': re.compile(r'^harbor-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.json$'),
}
for directory, pattern in authority_patterns.items():
    source_dir=root/directory
    if not source_dir.exists(): continue
    if source_dir.is_symlink() or not source_dir.is_dir(): raise SystemExit(1)
    for source in sorted(source_dir.iterdir()):
        if not pattern.fullmatch(source.name): raise SystemExit(1)
        value=json_value(source)
        if value.get('SCHEMA') != 1: raise SystemExit(1)
        copy(source, f'authority/{directory}/{source.name}')

# Generated recovery configuration is exact, not a recursive release copy.
release_files=('docker-compose.yml','common/config/nginx/nginx.conf','common/config/portal/nginx.conf')
current=root/'release/current'
for relative in release_files:
    source=current/relative
    if source.exists(): copy(source, 'config/'+relative)

# Durable Harbor stores are allowlisted by top-level class. Secret and runtime
# socket/transient trees are never members of the outer recovery archive.
durable_roots=('database','registry','jobservice','redis','trivy-adapter')
prohibited=re.compile(r'(secret|key|token|curl|robot|private[-_]?key|socket|transient)',re.I)
for top in durable_roots:
    source_root=data/top
    if not source_root.exists(): continue
    if source_root.is_symlink() or not source_root.is_dir(): raise SystemExit(1)
    for base, dirs, files in os.walk(source_root, followlinks=False):
        dirs[:]=sorted(d for d in dirs if not prohibited.search(d) and d.lower() not in {'tmp','run'})
        base_path=pathlib.Path(base)
        if any(prohibited.search(part) or part.lower() in {'tmp','run'} for part in base_path.relative_to(data).parts): raise SystemExit(1)
        for name in sorted(files):
            source=base_path/name
            if prohibited.search(name) or source.is_symlink(): raise SystemExit(1)
            copy(source, 'data/'+source.relative_to(data).as_posix())

# Secrets required to recover Harbor are an intentional, separately encrypted
# payload. Their plaintext paths never enter the outer archive or manifest.
secret_sources=[]
for source, relative in ((current/'harbor.yml','release/harbor.yml'), (data/'secret','data/secret')):
    if not source.exists(): continue
    if source.is_file(): secret_sources.append((source, relative))
    elif source.is_dir() and not source.is_symlink():
        for base, dirs, files in os.walk(source, followlinks=False):
            dirs.sort()
            if any((pathlib.Path(base)/name).is_symlink() for name in dirs): raise SystemExit(1)
            for name in sorted(files): secret_sources.append((pathlib.Path(base)/name, pathlib.PurePosixPath(relative)/pathlib.Path(base).relative_to(source)/name))
    else: raise SystemExit(1)
for source, relative in secret_sources: copy(source, str(relative), secrets)
PY
    secret_list="$(/usr/bin/find "$stage/secret-source" -type f -print -quit)"
    if [[ -n "$secret_list" ]]; then
        secret_tar="$stage/secret-payload.tar"; secret_cipher="$stage/payload/encrypted/secret-payload.age"
        /usr/bin/mkdir -m 0700 "$stage/payload/encrypted" || return 1
        /usr/bin/tar --format=pax --numeric-owner -C "$stage/secret-source" -cf "$secret_tar" . || return 1
        "$( _vx_harbor_age )" -R "$recipient" -o "$secret_cipher" "$secret_tar" || return 1
        /usr/bin/rm -rf -- "$secret_tar" "$stage/secret-source" || return 1
    else
        /usr/bin/rm -rf -- "$stage/secret-source" || return 1
    fi
    /usr/bin/python3 - "$stage/payload" <<'PY' || return 1
import hashlib, json, os, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); files=[]
for path in sorted(root.rglob('*')):
    if path.is_dir(): continue
    value=os.lstat(path)
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1: raise SystemExit(1)
    relative=path.relative_to(root).as_posix()
    cls='secret-ciphertext' if relative == 'encrypted/secret-payload.age' else ('authority' if relative.startswith('authority/') else ('config' if relative.startswith('config/') else 'data'))
    files.append({'PATH':relative,'CLASS':cls,'SHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'SIZE':value.st_size,'UID':value.st_uid,'GID':value.st_gid,'MODE':stat.S_IMODE(value.st_mode)})
manifest={'SCHEMA':2,'PROVIDER_VERSION':'v2.15.0','FILES':files}
(root/'manifest.json').write_text(json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n')
os.chmod(root/'manifest.json',0o600)
PY
}

_vx_harbor_restore_authority_validate() {
    local extract="$1" path name owner kind
    /usr/bin/grep -Eq '^age1[ac-hj-np-z02-9]{20,}$' "$extract/authority/backup-recipient.txt" || return 1
    for path in "$extract"/authority/owners/*.json; do [[ -f "$path" ]] || continue; _vx_harbor_authority_schema_validate owner "$path" "$(basename "$path" .json)" || return 1; done
    for path in "$extract"/authority/operations/*.json; do
        [[ -f "$path" ]] || continue; name="$(basename "$path" .json)"
        if [[ "$name" == provider-disable ]]; then
            _vx_harbor_authority_schema_validate disable-plan "$path" provider-disable || return 1
        else _vx_harbor_authority_schema_validate package-operation "$path" "$name" || return 1; fi
    done
    for path in "$extract"/authority/rotations/*.json; do [[ -f "$path" ]] || continue; name="$(basename "$path" .json)"; kind="${name##*-}"; owner="${name%-$kind}"; _vx_harbor_authority_schema_validate rotation "$path" "$owner:$kind" || return 1; done
    for path in "$extract"/authority/tombstones/*.json; do [[ -f "$path" ]] || continue; _vx_harbor_authority_schema_validate tombstone "$path" "$(basename "$path" .json)" || return 1; done
    for path in "$extract"/authority/backups/*.json; do [[ -f "$path" ]] || continue; _vx_harbor_authority_schema_validate backup "$path" "$(basename "$path" .json)" || return 1; done
    for path in "$extract"/authority/observations/*.json; do
        [[ -f "$path" ]] || continue; name="$(basename "$path" .json)"
        case "$name" in provider) kind=observation-provider;; provider-detail) kind=observation-detail;; *) kind=observation-owner;; esac
        _vx_harbor_authority_schema_validate "$kind" "$path" "$name" || return 1
    done
}

_vx_harbor_archive_create() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import pathlib, tarfile, sys
root, target=map(pathlib.Path,sys.argv[1:])
with tarfile.open(target,'w',format=tarfile.PAX_FORMAT) as archive:
    for path in [root/'manifest.json']+sorted(p for p in root.rglob('*') if p.is_file() and p.name != 'manifest.json'):
        archive.add(path,arcname=path.relative_to(root).as_posix(),recursive=False)
PY
}

vx_harbor_backup_locked() {
    local root layout recipient stage archive cipher metadata backup_id prior_running=no result=0 provider_source
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    root="$(vx_harbor_root)"; layout="$(vx_harbor_backup_layout_root)"; vx_harbor_provider_enabled || return 1
    recipient="$root/backup-recipient.txt"; vx_harbor_secure_regular_file "$recipient" 0600 || return 1
    backup_id="harbor-$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)-$(/usr/bin/od -An -N4 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    /usr/bin/mkdir -p "$layout"; /usr/bin/chown "$(_vx_harbor_authority_uid):$(_vx_harbor_authority_gid)" "$layout"; /usr/bin/chmod 0700 "$layout" || return 1
    stage="$(/usr/bin/mktemp -d "$root/.backup-stage.XXXXXX")" || return 1; /usr/bin/chmod 0700 "$stage"; VX_HARBOR_CLEANUP_STAGE="$stage"; trap '_vx_harbor_cleanup_stage; return 1' HUP INT TERM
    _vx_harbor_service_is_active && prior_running=yes || :
    [[ "$prior_running" == no ]] || _vx_harbor_service_stop || result=1
    (( result != 0 )) || _vx_harbor_backup_stage "$stage" "$recipient" || result=1
    archive="$stage/backup.tar"; cipher="$layout/$backup_id.tar.age"
    (( result != 0 )) || _vx_harbor_archive_create "$stage/payload" "$archive" || result=1
    (( result != 0 )) || "$( _vx_harbor_age )" -R "$recipient" -o "$stage/ciphertext" "$archive" || result=1
    /usr/bin/rm -f -- "$archive"
    [[ "$prior_running" == no ]] || _vx_harbor_service_start || result=1
    if (( result == 0 )); then
        /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$stage/ciphertext" "$cipher" || result=1
        metadata="$(/usr/bin/mktemp "$root/backups/.backup.XXXXXX")" || result=1
        if (( result == 0 )); then /usr/bin/jq -n --arg id "$backup_id" --arg file "${backup_id}.tar.age" --arg at "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$(/usr/bin/sha256sum "$cipher"|/usr/bin/awk '{print $1}')" '{SCHEMA:1,BACKUP_ID:$id,CIPHERTEXT:$file,SHA256:$sha,CREATED_AT:$at,VERSION:"v2.15.0"}' >"$metadata" && vx_harbor_json_write_atomic "$root/backups/$backup_id.json" "$metadata" || result=1; fi
        /usr/bin/rm -f -- "${metadata:-}"
        provider_source="$(/usr/bin/mktemp "$root/.provider-backup.XXXXXX")" || result=1
        if (( result == 0 )); then /usr/bin/jq --arg id "$backup_id" '.LAST_BACKUP_ID=$id' "$root/provider.json" >"$provider_source" && vx_harbor_json_write_atomic "$root/provider.json" "$provider_source" || result=1; fi
        /usr/bin/rm -f -- "${provider_source:-}"
    fi
    _vx_harbor_cleanup_stage; trap - HUP INT TERM
    (( result == 0 )) || { /usr/bin/rm -f -- "$cipher" "$root/backups/$backup_id.json"; return 1; }
    printf '%s\n' "$backup_id"
}

vx_harbor_backup() { local result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_backup_locked)"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }

_vx_harbor_restore_archive_validate() {
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import hashlib,json,os,pathlib,re,stat,sys,tarfile
archive,extract=map(pathlib.Path,sys.argv[1:3]); available=int(sys.argv[3]); extract.mkdir(mode=0o700)
authority=re.compile(r'^authority/(provider\.json|backup-recipient\.txt|owners/[a-z0-9][a-z0-9_-]{0,31}\.json|observations/(provider|provider-detail|[a-z0-9][a-z0-9_-]{0,31})\.json|operations/(provider-disable|[a-z0-9][a-z0-9_-]{0,31})\.json|rotations/[a-z0-9][a-z0-9_-]{0,31}-(runtime|publisher)\.json|tombstones/[a-z0-9][a-z0-9_-]{0,31}\.json|backups/harbor-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}\.json)$')
config={'config/docker-compose.yml','config/common/config/nginx/nginx.conf','config/common/config/portal/nginx.conf'}
data=re.compile(r'^data/(database|registry|jobservice|redis|trivy-adapter)/.+$')
prohibited=re.compile(r'(secret|key|token|curl|robot|private[-_]?key|socket|transient)',re.I)
with tarfile.open(archive,'r:*') as t:
    members=t.getmembers(); names=[m.name for m in members]
    if len(names)!=len(set(names)) or names.count('manifest.json')!=1: raise SystemExit(1)
    for m in members:
        n=m.name
        if not n or n.startswith('/') or '..' in pathlib.PurePosixPath(n).parts or '\\' in n or not m.isfile() or m.issym() or m.islnk(): raise SystemExit(1)
    raw=t.extractfile('manifest.json').read(1048577)
    if len(raw)>1048576: raise SystemExit(1)
    manifest=json.loads(raw)
    if set(manifest)!={'SCHEMA','PROVIDER_VERSION','FILES'} or manifest['SCHEMA']!=2 or manifest['PROVIDER_VERSION']!='v2.15.0' or not isinstance(manifest['FILES'],list): raise SystemExit(1)
    records={}
    for item in manifest['FILES']:
        if set(item)!={'PATH','CLASS','SHA256','SIZE','UID','GID','MODE'}: raise SystemExit(1)
        p=item['PATH']; cls=item['CLASS']
        if p in records or p=='manifest.json' or p.startswith('/') or '..' in pathlib.PurePosixPath(p).parts or '\\' in p: raise SystemExit(1)
        if cls not in {'authority','config','data','secret-ciphertext'} or (cls=='secret-ciphertext') != (p=='encrypted/secret-payload.age'): raise SystemExit(1)
        if cls=='authority' and not p.startswith('authority/'): raise SystemExit(1)
        if cls=='config' and not p.startswith('config/'): raise SystemExit(1)
        if cls=='data' and not p.startswith('data/'): raise SystemExit(1)
        if cls=='authority' and not authority.fullmatch(p): raise SystemExit(1)
        if cls=='config' and p not in config: raise SystemExit(1)
        if cls=='data' and (not data.fullmatch(p) or any(prohibited.search(x) or x.lower() in {'tmp','run'} for x in pathlib.PurePosixPath(p).parts)): raise SystemExit(1)
        if not re.fullmatch(r'[a-f0-9]{64}',str(item['SHA256'])) or not all(isinstance(item[k],int) and not isinstance(item[k],bool) for k in ('SIZE','UID','GID','MODE')): raise SystemExit(1)
        if item['SIZE']<0 or not 0<=item['UID']<=65535 or not 0<=item['GID']<=65535 or not 0<=item['MODE']<=0o777 or item['MODE']&0o022: raise SystemExit(1)
        records[p]=item
    if set(names) != {'manifest.json',*records}: raise SystemExit(1)
    if sum(item['SIZE'] for item in records.values()) + archive.stat().st_size > available: raise SystemExit(1)
    for name,item in records.items():
        member=t.getmember(name)
        if member.size!=item['SIZE'] or member.uid!=item['UID'] or member.gid!=item['GID'] or (member.mode&0o777)!=item['MODE']: raise SystemExit(1)
        content=t.extractfile(member).read()
        if len(content)!=item['SIZE'] or hashlib.sha256(content).hexdigest()!=item['SHA256']: raise SystemExit(1)
        target=extract/name; target.parent.mkdir(parents=True,exist_ok=True,mode=0o700); target.write_bytes(content); os.chmod(target,item['MODE'])
        try: os.chown(target,item['UID'],item['GID'])
        except PermissionError:
            if (item['UID'],item['GID']) != (os.getuid(),os.getgid()): raise SystemExit(1)
        actual=os.lstat(target)
        if not stat.S_ISREG(actual.st_mode) or (actual.st_uid,actual.st_gid,stat.S_IMODE(actual.st_mode)) != (item['UID'],item['GID'],item['MODE']): raise SystemExit(1)

def obj(path):
    value=json.loads(path.read_text())
    if not isinstance(value,dict): raise SystemExit(1)
    return value
provider=obj(extract/'authority/provider.json')
if set(provider)!={'SCHEMA','MODE','PINNED_VERSION','RUNNING_VERSION','INSTALLATION_ID','ORIGIN','RELEASE_MANIFEST_SHA256','LAST_HEALTH_AT','LAST_BACKUP_ID','LAST_RESTORE_TEST_AT','LAST_UPGRADE'} or provider['SCHEMA']!=1 or provider['PINNED_VERSION']!='v2.15.0': raise SystemExit(1)
for path in (extract/'authority').rglob('*.json'):
    value=obj(path)
    if value.get('SCHEMA',1)!=1: raise SystemExit(1)
    rel=path.relative_to(extract).as_posix()
    if '/owners/' in rel:
        if {'SCHEMA','OWNER','NAMESPACE','PROJECT_ID','QUOTA_ID','QUOTA_MB','STATE','RUNTIME_ROBOT_ID','RUNTIME_USERNAME','PUBLISHER_ROBOT_ID','PUBLISHER_USERNAME','PUBLISHER_ENABLED','LAST_ERROR','UPDATED_AT'}!=set(value) or value['STATE'] not in {'project-ready','runtime-ready','publisher-ready','publisher-disabled','retained','unavailable'}: raise SystemExit(1)
    if '/backups/' in rel:
        if set(value)!={'SCHEMA','BACKUP_ID','CIPHERTEXT','SHA256','CREATED_AT','VERSION'} or value['VERSION']!='v2.15.0' or not re.fullmatch(r'[a-f0-9]{64}',str(value['SHA256'])): raise SystemExit(1)
    if '/observations/' in rel:
        keys=set(value)
        if not (keys=={'SCHEMA','GENERATION','OBSERVED_AT','USED_MB'} or keys=={'SCHEMA','HEALTH','OBSERVED_AT'} or keys=={'SCHEMA','OBSERVED_AT','HEALTH','CERTIFICATE','STORAGE','OPERATIONS','OWNERS'}): raise SystemExit(1)
PY
}

vx_harbor_restore_validate_locked() {
    local id="$1" root metadata layout cipher stage archive identity result=0 available
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive && "$id" =~ ^harbor-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || return 1
    root="$(vx_harbor_root)"; layout="$(vx_harbor_backup_layout_root)"; metadata="$root/backups/$id.json"
    vx_harbor_secure_regular_file "$metadata" 0600 || return 1
    /usr/bin/jq -e --arg id "$id" 'keys==["BACKUP_ID","CIPHERTEXT","CREATED_AT","SCHEMA","SHA256","VERSION"] and .SCHEMA==1 and .BACKUP_ID==$id and .VERSION=="v2.15.0" and (.CIPHERTEXT==($id+".tar.age")) and (.SHA256|test("^[a-f0-9]{64}$"))' "$metadata" >/dev/null || return 1
    cipher="$layout/$id.tar.age"; vx_harbor_secure_regular_file "$cipher" 0600 || return 1
    [[ "$(/usr/bin/sha256sum "$cipher"|/usr/bin/awk '{print $1}')" == "$(/usr/bin/jq -r .SHA256 "$metadata")" ]] || return 1
    identity="$root/secrets/backup.agekey"; vx_harbor_secure_regular_file "$identity" 0600 || return 1
    stage="$(/usr/bin/mktemp -d "$root/.restore-validate.XXXXXX")" || return 1; /usr/bin/chmod 0700 "$stage"; VX_HARBOR_CLEANUP_STAGE="$stage"; trap '_vx_harbor_cleanup_stage; return 1' HUP INT TERM; archive="$stage/backup.tar"
    "$( _vx_harbor_age )" -d -i "$identity" -o "$archive" "$cipher" || result=1
    if (( result == 0 )); then available="$(/usr/bin/df -Pk "$root" | /usr/bin/awk 'NR==2{print $4*1024}')" || result=1; [[ "$available" =~ ^[0-9]+$ ]] || result=1; fi
    (( result != 0 )) || _vx_harbor_restore_archive_validate "$archive" "$stage/extract" "$available" || result=1
    (( result != 0 )) || _vx_harbor_restore_authority_validate "$stage/extract" || result=1
    _vx_harbor_cleanup_stage; trap - HUP INT TERM
    (( result == 0 )) || return 1
    printf 'validated\n'
}

vx_harbor_restore() { local id="$1" mode="$2" result status; [[ "$mode" == validate ]] || return "$VX_HARBOR_RESTORE_APPLY_DEFERRED"; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_restore_validate_locked "$id")"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }
