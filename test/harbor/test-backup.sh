#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; new_vesta_root; trap cleanup_vesta_root EXIT; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ :; }; _vx_harbor_authority_uid(){ id -u; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }; vx_harbor_provider_prepare
root="$(vx_harbor_root)"; tmp="$(mktemp "$root/.provider.XXXXXX")"; jq '.MODE="managed"' "$root/provider.json" >"$tmp"; vx_harbor_json_write_atomic "$root/provider.json" "$tmp"; rm -f "$tmp"
printf 'age1fixture\n' >"$root/backup-recipient.txt"; printf 'AGE-SECRET-KEY-fixture\n' >"$root/secrets/backup.agekey"; chmod 0600 "$root/backup-recipient.txt" "$root/secrets/backup.agekey"
test_data="$HARBOR_TEST_ROOT/provider-data"; mkdir -p "$test_data/blobs"; printf artifact >"$test_data/blobs/value"; vx_harbor_data_root(){ printf '%s\n' "$test_data"; }
layout="$HARBOR_TEST_ROOT/system-backups"; VX_HARBOR_BACKUP_LAYOUT_ROOT="$layout"; service_log="$HARBOR_TEST_ROOT/service.log"; _vx_harbor_service_is_active(){ return 0; }; _vx_harbor_service_stop(){ echo stop >>"$service_log"; }; _vx_harbor_service_start(){ echo start >>"$service_log"; }
fake_age="$HARBOR_TEST_ROOT/age"; printf '#!/bin/sh\nif [ "$1" = -d ]; then cp "$6" "$5"; else cp "$5" "$4"; fi\n' >"$fake_age"; chmod +x "$fake_age"; VX_HARBOR_AGE="$fake_age"
vx_harbor_provider_lock_acquire exclusive; id="$(vx_harbor_backup_locked)"; vx_harbor_provider_lock_release
[[ "$(tr '\n' ':' <"$service_log")" == stop:start: && -f "$layout/$id.tar.age" ]] || fail 'backup did not quiesce/restart or persist ciphertext'
tar -tf "$layout/$id.tar.age" | grep -Eq 'curl|agekey|socket' && fail 'backup included secret/transient material'
vx_harbor_provider_lock_acquire exclusive; vx_harbor_restore_validate_locked "$id" >/dev/null || fail 'valid encrypted backup rejected'; vx_harbor_provider_lock_release
[[ ! -e "$root/.restore-validate" ]] || fail 'restore plaintext survived validation'
set +e; vx_harbor_restore "$id" apply >/dev/null 2>&1; code=$?; set -e; [[ "$code" == 78 ]] || fail 'restore apply did not return stable deferred code'
printf 'PASS: encrypted backup and validate-only restore\n'
