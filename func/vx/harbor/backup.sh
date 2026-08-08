#!/usr/bin/env bash

VX_HARBOR_RESTORE_APPLY_DEFERRED=78

vx_harbor_backup_layout_root() { printf '%s\n' "${VX_HARBOR_BACKUP_LAYOUT_ROOT:-$VESTA/data/backup/harbor}"; }
_vx_harbor_service_is_active() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-active vesta-harbor.service >/dev/null 2>&1; }
_vx_harbor_service_stop() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service; }
_vx_harbor_service_start() { "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service; }
_vx_harbor_age() { printf '%s\n' "${VX_HARBOR_AGE:-/usr/bin/age}"; }

_vx_harbor_backup_stage() {
    local stage="$1" root data manifest file relative
    root="$(vx_harbor_root)"; data="$(vx_harbor_data_root)"
    /usr/bin/mkdir -p "$stage/authority" "$stage/data" || return 1
    /usr/bin/chmod 0700 "$stage" "$stage/authority" "$stage/data" || return 1
    for file in provider.json backup-recipient.txt release; do
        [[ -e "$root/$file" ]] || continue
        /usr/bin/cp -a --no-dereference "$root/$file" "$stage/authority/" || return 1
    done
    for file in owners observations operations rotations tombstones; do
        [[ -e "$root/$file" ]] && /usr/bin/cp -a --no-dereference "$root/$file" "$stage/authority/" || :
    done
    [[ -d "$data" && ! -L "$data" ]] || return 1
    /usr/bin/cp -a --no-dereference "$data/." "$stage/data/" || return 1
    if /usr/bin/find "$stage" \( -type s -o -type p -o -type b -o -type c -o -type l \) -print -quit | /usr/bin/grep -q .; then return 1; fi
    if /usr/bin/find "$stage" -type f \( -name '*.curl' -o -name '*.agekey' -o -name '*robot*secret*' -o -name '*.key' \) -print -quit | /usr/bin/grep -q .; then return 1; fi
    manifest="$stage/manifest.json"
    (cd "$stage" && /usr/bin/find authority data -type f -print0 | /usr/bin/sort -z | while IFS= read -r -d '' relative; do /usr/bin/sha256sum -- "$relative"; done) \
      | /usr/bin/jq -Rsc --arg version v2.15.0 'split("\n")|map(select(length>0)|capture("^(?<sha>[a-f0-9]{64})  (?<path>.+)$"))|{SCHEMA:1,PROVIDER_VERSION:$version,FILES:map({PATH:.path,SHA256:.sha})}' >"$manifest" || return 1
    /usr/bin/chmod 0600 "$manifest"
}

vx_harbor_backup_locked() {
    local root layout recipient stage archive cipher metadata backup_id prior_running=no result=0 provider_source
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    root="$(vx_harbor_root)"; layout="$(vx_harbor_backup_layout_root)"
    vx_harbor_provider_enabled || return 1
    recipient="$root/backup-recipient.txt"; vx_harbor_secure_regular_file "$recipient" 0600 || return 1
    backup_id="harbor-$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)-$(/usr/bin/od -An -N4 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    /usr/bin/mkdir -p "$layout"; /usr/bin/chown "$(_vx_harbor_authority_uid):$(_vx_harbor_authority_gid)" "$layout"; /usr/bin/chmod 0700 "$layout" || return 1
    stage="$(/usr/bin/mktemp -d "$root/.backup-stage.XXXXXX")" || return 1; /usr/bin/chmod 0700 "$stage"
    _vx_harbor_service_is_active && prior_running=yes || :
    [[ "$prior_running" == no ]] || _vx_harbor_service_stop || result=1
    if (( result == 0 )); then _vx_harbor_backup_stage "$stage/payload" || result=1; fi
    archive="$stage/backup.tar"; cipher="$layout/$backup_id.tar.age"
    if (( result == 0 )); then /usr/bin/tar --format=pax --numeric-owner --owner=0 --group=0 -C "$stage/payload" -cf "$archive" . || result=1; fi
    if (( result == 0 )); then "$( _vx_harbor_age )" -R "$recipient" -o "$stage/ciphertext" "$archive" || result=1; fi
    /usr/bin/rm -f -- "$archive"
    if [[ "$prior_running" == yes ]]; then _vx_harbor_service_start || result=1; fi
    if (( result == 0 )); then
        /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$stage/ciphertext" "$cipher" || result=1
        metadata="$(/usr/bin/mktemp "$root/backups/.backup.XXXXXX")" || result=1
        if (( result == 0 )); then /usr/bin/jq -n --arg id "$backup_id" --arg file "${backup_id}.tar.age" --arg at "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$(/usr/bin/sha256sum "$cipher"|/usr/bin/awk '{print $1}')" '{SCHEMA:1,BACKUP_ID:$id,CIPHERTEXT:$file,SHA256:$sha,CREATED_AT:$at,VERSION:"v2.15.0"}' >"$metadata" && vx_harbor_json_write_atomic "$root/backups/$backup_id.json" "$metadata" || result=1; fi
        /usr/bin/rm -f -- "${metadata:-}"
        provider_source="$(/usr/bin/mktemp "$root/.provider-backup.XXXXXX")" || result=1
        if (( result == 0 )); then /usr/bin/jq --arg id "$backup_id" '.LAST_BACKUP_ID=$id' "$root/provider.json" >"$provider_source" && vx_harbor_json_write_atomic "$root/provider.json" "$provider_source" || result=1; fi
        /usr/bin/rm -f -- "${provider_source:-}"
    fi
    /usr/bin/rm -rf -- "$stage"
    (( result == 0 )) || { /usr/bin/rm -f -- "$cipher" "$root/backups/$backup_id.json"; return 1; }
    printf '%s\n' "$backup_id"
}

vx_harbor_backup() { local result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_backup_locked)"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }

vx_harbor_restore_validate_locked() {
    local id="$1" root metadata layout cipher stage archive identity result=0 required available
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive && "$id" =~ ^harbor-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$ ]] || return 1
    root="$(vx_harbor_root)"; layout="$(vx_harbor_backup_layout_root)"; metadata="$root/backups/$id.json"
    vx_harbor_secure_regular_file "$metadata" 0600 || return 1
    /usr/bin/jq -e --arg id "$id" 'keys==["BACKUP_ID","CIPHERTEXT","CREATED_AT","SCHEMA","SHA256","VERSION"] and .SCHEMA==1 and .BACKUP_ID==$id and .VERSION=="v2.15.0" and (.CIPHERTEXT==($id+".tar.age")) and (.SHA256|test("^[a-f0-9]{64}$"))' "$metadata" >/dev/null || return 1
    cipher="$layout/$id.tar.age"; vx_harbor_secure_regular_file "$cipher" 0600 || return 1
    [[ "$(/usr/bin/sha256sum "$cipher"|/usr/bin/awk '{print $1}')" == "$(/usr/bin/jq -r .SHA256 "$metadata")" ]] || return 1
    identity="$root/secrets/backup.agekey"; vx_harbor_secure_regular_file "$identity" 0600 || return 1
    stage="$(/usr/bin/mktemp -d "$root/.restore-validate.XXXXXX")" || return 1; /usr/bin/chmod 0700 "$stage"; archive="$stage/backup.tar"
    "$( _vx_harbor_age )" -d -i "$identity" -o "$archive" "$cipher" || result=1
    if (( result == 0 )); then /usr/bin/python3 - "$archive" <<'PY' || result=1
import os, stat, sys, tarfile
p=sys.argv[1]
with tarfile.open(p, 'r:*') as t:
    seen=set()
    for m in t.getmembers():
        n=m.name.removeprefix('./')
        if n in ('', '.') and m.isdir():
            continue
        if not n or n in seen or n.startswith('/') or '..' in n.split('/'):
            raise SystemExit(1)
        seen.add(n)
        if not (m.isfile() or m.isdir()) or m.issym() or m.islnk() or m.uid != 0 or m.gid != 0:
            raise SystemExit(1)
        if not (n == 'manifest.json' or n in ('authority', 'data') or n.startswith('authority/') or n.startswith('data/')):
            raise SystemExit(1)
    member=next((x for x in t.getmembers() if x.name.removeprefix('./') == 'manifest.json'), None)
    manifest=t.extractfile(member) if member is not None else None
    if manifest is None or manifest.read(1<<20).startswith(b'{') is False:
        raise SystemExit(1)
PY
    fi
    if (( result == 0 )); then
        required="$(/usr/bin/python3 - "$archive" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:*') as t: print(sum(m.size for m in t.getmembers() if m.isfile()))
PY
)" || result=1
        available="$(/usr/bin/df -Pk "$root" | /usr/bin/awk 'NR==2{print $4*1024}')" || result=1
        [[ "$required" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$required" -le "$available" ]] || result=1
    fi
    if (( result == 0 )); then
        /usr/bin/mkdir "$stage/extract" && /usr/bin/tar --no-same-owner --no-same-permissions -xf "$archive" -C "$stage/extract" || result=1
        /usr/bin/jq -e '.SCHEMA==1 and .PROVIDER_VERSION=="v2.15.0" and (.FILES|type=="array")' "$stage/extract/manifest.json" >/dev/null 2>&1 || result=1
    fi
    if (( result == 0 )); then (cd "$stage/extract" && /usr/bin/jq -r '.FILES[]|[.SHA256,.PATH]|@tsv' manifest.json | while IFS=$'\t' read -r sha path; do [[ "$path" == authority/* || "$path" == data/* ]] && [[ -f "$path" && ! -L "$path" ]] && [[ "$(/usr/bin/sha256sum "$path"|/usr/bin/awk '{print $1}')" == "$sha" ]] || exit 1; done) || result=1; fi
    /usr/bin/rm -rf -- "$stage"
    (( result == 0 )) || return 1
    printf 'validated\n'
}

vx_harbor_restore() { local id="$1" mode="$2" result status; [[ "$mode" == validate ]] || return "$VX_HARBOR_RESTORE_APPLY_DEFERRED"; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_restore_validate_locked "$id")"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }
