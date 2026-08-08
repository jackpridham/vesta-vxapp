#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; new_vesta_root; trap cleanup_vesta_root EXIT; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ :; }; _vx_harbor_authority_uid(){ id -u; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }; vx_harbor_provider_prepare
root="$(vx_harbor_root)"; tmp="$(mktemp "$root/.provider.XXXXXX")"; jq '.MODE="managed"' "$root/provider.json" >"$tmp"; vx_harbor_json_write_atomic "$root/provider.json" "$tmp"; rm -f "$tmp"

identity="$root/secrets/backup.agekey"; age-keygen -o "$identity" >/dev/null 2>&1; age-keygen -y "$identity" >"$root/backup-recipient.txt"; chmod 0600 "$identity" "$root/backup-recipient.txt"
release="$root/release/current"; mkdir -p "$release/common/config/nginx" "$release/common/config/portal"
printf 'services: {}\n' >"$release/docker-compose.yml"; printf 'events {}\n' >"$release/common/config/nginx/nginx.conf"; printf 'server {}\n' >"$release/common/config/portal/nginx.conf"
printf 'harbor_admin_password: ADMIN_SECRET_SENTINEL\n' >"$release/harbor.yml"
test_data="$HARBOR_TEST_ROOT/provider-data"; mkdir -p "$test_data/database" "$test_data/registry/docker/registry/v2/blobs" "$test_data/jobservice" "$test_data/secret/keys" "$test_data/registry/token-cache" "$test_data/registry/curl-config"
printf database >"$test_data/database/harbor.db"; printf artifact >"$test_data/registry/docker/registry/v2/blobs/value"; printf jobs >"$test_data/jobservice/jobs.db"
printf CANONICAL_SECRET_SENTINEL >"$test_data/secret/keys/secretkey"; printf TOKEN_SECRET_SENTINEL >"$test_data/registry/token-cache/value"; printf CURL_SECRET_SENTINEL >"$test_data/registry/curl-config/value"
chmod 0640 "$test_data/database/harbor.db"; vx_harbor_data_root(){ printf '%s\n' "$test_data"; }
layout="$HARBOR_TEST_ROOT/system-backups"; VX_HARBOR_BACKUP_LAYOUT_ROOT="$layout"; service_log="$HARBOR_TEST_ROOT/service.log"; _vx_harbor_service_is_active(){ return 0; }; _vx_harbor_service_stop(){ echo stop >>"$service_log"; }; _vx_harbor_service_start(){ echo start >>"$service_log"; }

vx_harbor_provider_lock_acquire exclusive; id="$(vx_harbor_backup_locked)"; vx_harbor_provider_lock_release
[[ "$(tr '\n' ':' <"$service_log")" == stop:start: && -f "$layout/$id.tar.age" ]] || fail 'backup did not quiesce/restart or persist ciphertext'
outer="$HARBOR_TEST_ROOT/outer.tar"; age -d -i "$identity" -o "$outer" "$layout/$id.tar.age"
members="$(tar -tf "$outer")"; grep -Eq '(^|/)(secret|keys?|tokens?|curl|robots?|private[-_]?key)(/|$)' <<<"$members" && fail 'outer archive included a prohibited plaintext path'
jq -e '.SCHEMA==2 and ([.FILES[]|select(.CLASS=="secret-ciphertext" and .PATH=="encrypted/secret-payload.age")]|length)==1 and ([.FILES[]|select(.PATH=="data/database/harbor.db" and .MODE==416)]|length)==1' < <(tar -xOf "$outer" manifest.json) >/dev/null || fail 'manifest did not classify ciphertext or preserve source mode'
for secret in ADMIN_SECRET_SENTINEL CANONICAL_SECRET_SENTINEL TOKEN_SECRET_SENTINEL CURL_SECRET_SENTINEL; do
    grep -aFq "$secret" "$outer" && fail 'plaintext secret escaped into decrypted outer archive'
    grep -RFq "$secret" "$root/backups" "$layout" "$service_log" && fail 'plaintext secret escaped into metadata or logs'
done
vx_harbor_provider_lock_acquire exclusive; vx_harbor_restore_validate_locked "$id" >/dev/null || fail 'valid encrypted backup rejected'; vx_harbor_provider_lock_release

base="$HARBOR_TEST_ROOT/base.tar"; cp "$outer" "$base"
authority_before="$(sha256sum "$root/provider.json" "$test_data/database/harbor.db")"
make_variant() {
    /usr/bin/python3 - "$base" "$outer" "$1" <<'PY'
import hashlib,io,json,sys,tarfile
source,target,kind=sys.argv[1:]
with tarfile.open(source) as archive:
    items=[(m,archive.extractfile(m).read()) for m in archive.getmembers()]
manifest=json.loads(next(data for member,data in items if member.name=='manifest.json'))
payload={member.name:data for member,data in items if member.name!='manifest.json'}
def record(path,content,cls='authority'):
    manifest['FILES'].append({'PATH':path,'CLASS':cls,'SHA256':hashlib.sha256(content).hexdigest(),'SIZE':len(content),'UID':0,'GID':0,'MODE':0o600})
if kind=='unexpected': payload['unexpected.txt']=b'x'
elif kind=='missing': payload.pop(manifest['FILES'][0]['PATH'])
elif kind=='manifest-duplicate': manifest['FILES'].append(dict(manifest['FILES'][0]))
elif kind=='provider-schema':
    path='authority/provider.json'; value=json.loads(payload[path]); value['SCHEMA']=9; payload[path]=(json.dumps(value)+'\n').encode(); item=next(x for x in manifest['FILES'] if x['PATH']==path); item.update(SHA256=hashlib.sha256(payload[path]).hexdigest(),SIZE=len(payload[path]))
elif kind=='observation-schema':
    payload['authority/observations/alice.json']=b'{"SCHEMA":1,"OBSERVED_AT":"bad"}\n'; record('authority/observations/alice.json',payload['authority/observations/alice.json'])
elif kind=='backup-schema':
    path='authority/backups/harbor-20260808T000000Z-00000000.json'; payload[path]=b'{"SCHEMA":1}\n'; record(path,payload[path])
with tarfile.open(target,'w',format=tarfile.PAX_FORMAT) as archive:
    manifest_raw=(json.dumps(manifest,separators=(',',':'),sort_keys=True)+'\n').encode()
    info=tarfile.TarInfo('manifest.json'); info.size=len(manifest_raw); info.mode=0o600; archive.addfile(info,io.BytesIO(manifest_raw))
    for member,data in items:
        if member.name=='manifest.json' or member.name not in payload: continue
        member.size=len(payload[member.name]); archive.addfile(member,io.BytesIO(payload[member.name]))
    if kind=='duplicate':
        member,data=next((m,d) for m,d in items if m.name!='manifest.json'); archive.addfile(member,io.BytesIO(data))
    elif kind=='link':
        info=tarfile.TarInfo('authority/link'); info.type=tarfile.SYMTYPE; info.linkname='provider.json'; archive.addfile(info)
    elif kind=='traversal':
        info=tarfile.TarInfo('../escape'); info.size=1; archive.addfile(info,io.BytesIO(b'x'))
    elif kind=='mode-mismatch':
        pass
    for path,data in payload.items():
        if path not in {m.name for m,_ in items}: info=tarfile.TarInfo(path); info.size=len(data); info.mode=0o600; archive.addfile(info,io.BytesIO(data))
if kind=='mode-mismatch':
    # Rebuild one member mode without changing its manifest record.
    with tarfile.open(target) as archive: rebuilt=[(m,archive.extractfile(m).read()) for m in archive.getmembers()]
    with tarfile.open(target,'w',format=tarfile.PAX_FORMAT) as archive:
        changed=False
        for member,data in rebuilt:
            if member.name!='manifest.json' and not changed: member.mode ^= 0o100; changed=True
            archive.addfile(member,io.BytesIO(data))
PY
}
for variant in unexpected missing duplicate link traversal manifest-duplicate mode-mismatch provider-schema observation-schema backup-schema; do
    make_variant "$variant"; rm -f "$layout/$id.tar.age"; age -R "$root/backup-recipient.txt" -o "$layout/$id.tar.age" "$outer"; sha="$(sha256sum "$layout/$id.tar.age"|awk '{print $1}')"; jq --arg sha "$sha" '.SHA256=$sha' "$root/backups/$id.json" >"$tmp"; vx_harbor_json_write_atomic "$root/backups/$id.json" "$tmp"
    set +e; vx_harbor_provider_lock_acquire exclusive; vx_harbor_restore_validate_locked "$id" >/dev/null 2>&1; code=$?; vx_harbor_provider_lock_release; set -e
    [[ "$code" != 0 ]] || fail "restore accepted adversarial $variant archive"
    ! find "$root" -maxdepth 1 -name '.restore-validate.*' -print -quit | grep -q . || fail "restore left plaintext after $variant failure"
done
[[ "$(sha256sum "$root/provider.json" "$test_data/database/harbor.db")" == "$authority_before" ]] || fail 'validate-only restore mutated provider authority or data'
set +e; vx_harbor_restore "$id" apply >/dev/null 2>&1; code=$?; set -e; [[ "$code" == 78 ]] || fail 'restore apply did not return stable deferred code'
printf 'PASS: allowlisted encrypted backup and exact validate-only restore\n'
