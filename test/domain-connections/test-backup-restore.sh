#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID != 0 ]]; then exec sudo -n bash "$0" "$@"; fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export VESTA="$tmp/vesta"
mkdir -p "$VESTA/data/users/alice"

# shellcheck source=func/vx/domain-connections/state.sh
source "$root/func/vx/domain-connections/state.sh"
# shellcheck source=func/vx/domain-connections/backup.sh
source "$root/func/vx/domain-connections/backup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
hostname='shop.customer.example'
parent='technical.vxapp.example'
id='connection-backup-001'
record=$(jq -cn --arg host "$hostname" --arg parent "$parent" --arg id "$id" \
    '{VERSION:1,OWNER:"alice",TECHNICAL_FQDN:$parent,HOSTNAME:$host,
      CONNECTION_ID:$id,GENERATION:4,PROOF_TOKEN:"must-not-back-up",
      PROOF_EXPIRES_AT:"2026-09-16T00:00:00Z",STATE:"connected",
      REASON:"https_accepted",CREATED_AT:"2026-09-15T00:00:00Z",
      LAST_CHECKED_AT:null,LAST_SUCCESSFUL_AT:null,NEXT_CHECK_AT:null,
      OBSERVATIONS:{native:{TLS_STATE:"accepted"},PROXY_HEADERS:"private"},
      CLEANUP:{NATIVE_CHILD:true}}')

vx_domain_connection_prepare
vx_domain_connection_record_write "$hostname" "$record"
backup="$tmp/backup/vesta/domain-connections"
vx_domain_connection_backup_user alice "$backup"
manifest="$backup/$(vx_domain_connection_hash "$hostname").json"
[[ $(stat -c '%a' "$backup") == 700 && $(stat -c '%a' "$manifest") == 600 ]] \
    || fail 'backup permissions are not protected'
jq -e '.REGISTRY_SHA256|test("^[0-9a-f]{64}$")' "$manifest" >/dev/null \
    || fail 'backup lacks an exact registry digest'
if grep -Eq 'must-not-back-up|PROXY_HEADERS|private' "$manifest"; then
    fail 'backup disclosed proof or private proxy metadata'
fi

# A byte-for-byte same registry relation may already be owned locally.
vx_domain_connection_restore_preflight alice "$backup" \
    || fail 'same-owner exact registry recovery was rejected'

# Same owner is insufficient: an updated generation leaves the global record
# untouched and blocks the restore before any child can be routed.
changed=$(jq '.GENERATION=5' <<<"$record")
vx_domain_connection_record_write "$hostname" "$changed"
if vx_domain_connection_restore_preflight alice "$backup"; then
    fail 'stale generation was accepted'
fi
[[ $(vx_domain_connection_record_read "$hostname" | jq -r .GENERATION) == 5 ]] \
    || fail 'conflicting registry was changed during preflight'

# An absent registry is recoverable only after the native parent and exact
# child marker are reconstructed. The imported record remains recovery-only.
rm -f -- "$(vx_domain_connection_record_path "$hostname")"
vx_domain_connection_restore_preflight alice "$backup" \
    || fail 'empty registry preflight failed'
cat >"$VESTA/data/users/alice/web.conf" <<EOF
DOMAIN='$parent' LETSENCRYPT='no' SSL='yes'
DOMAIN='$hostname' ALIAS='' SSL='yes' LETSENCRYPT='yes' VX_CONNECTION_ID='$id' VX_CONNECTION_PARENT='$parent' VX_CONNECTION_GENERATION='4'
EOF
# Archive preflight must inspect the archived rows, independently of whatever
# native state already exists at the destination.
archive_root="$tmp/archive"
mkdir -p "$archive_root/web/$hostname/vesta" "$archive_root/web/$parent/vesta"
grep -F "DOMAIN='$hostname'" "$VESTA/data/users/alice/web.conf" >"$archive_root/web/$hostname/vesta/web.conf"
grep -F "DOMAIN='$parent'" "$VESTA/data/users/alice/web.conf" >"$archive_root/web/$parent/vesta/web.conf"
tar -cf "$tmp/valid.tar" -C "$archive_root" ./web
mv "$VESTA/data/users/alice/web.conf" "$tmp/live-web.conf"
vx_domain_connection_restore_archive_preflight alice "$backup" "$tmp/valid.tar" \
    || fail 'valid archive required preexisting live native rows'
mv "$tmp/live-web.conf" "$VESTA/data/users/alice/web.conf"
sed -i "s/VX_CONNECTION_GENERATION='4'/VX_CONNECTION_GENERATION='3'/" "$archive_root/web/$hostname/vesta/web.conf"
tar -cf "$tmp/stale.tar" -C "$archive_root" ./web
if vx_domain_connection_restore_archive_preflight alice "$backup" "$tmp/stale.tar"; then
    fail 'valid live rows concealed stale archived authority'
fi
vx_domain_connection_restore_commit alice "$backup" \
    || fail 'same-owner recovery did not commit'
restored=$(vx_domain_connection_record_read "$hostname")
[[ $(jq -r .STATE <<<"$restored") == recovery_required \
    && $(jq -r .RESTORED_STATE <<<"$restored") == connected \
    && $(jq -r .PROOF_TOKEN <<<"$restored") == null ]] \
    || fail 'recovery state retained live proof authority'

# A missing technical parent must retain no newly created registry authority.
rm -f -- "$(vx_domain_connection_record_path "$hostname")"
printf "DOMAIN='%s' ALIAS='' SSL='yes' LETSENCRYPT='yes' VX_CONNECTION_ID='%s' VX_CONNECTION_PARENT='%s' VX_CONNECTION_GENERATION='4'\n" \
    "$hostname" "$id" "$parent" >"$VESTA/data/users/alice/web.conf"
if vx_domain_connection_restore_commit alice "$backup"; then
    fail 'missing parent was accepted'
fi
[[ ! -e $(vx_domain_connection_record_path "$hostname") ]] \
    || fail 'missing-parent failure claimed registry authority'

# A stale native marker likewise cannot claim the hostname on restore.
cat >"$VESTA/data/users/alice/web.conf" <<EOF
DOMAIN='$parent' LETSENCRYPT='no' SSL='yes'
DOMAIN='$hostname' ALIAS='' SSL='yes' LETSENCRYPT='yes' VX_CONNECTION_ID='$id' VX_CONNECTION_PARENT='$parent' VX_CONNECTION_GENERATION='3'
EOF
if vx_domain_connection_restore_commit alice "$backup"; then
    fail 'stale native generation was accepted'
fi
[[ ! -e $(vx_domain_connection_record_path "$hostname") ]] \
    || fail 'stale marker claimed registry authority'

printf 'domain connection backup/restore tests passed\n'
