#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

for command_name in v-migrate-host v-migrate-user; do
    command_path="$repo_root/bin/$command_name"
    [[ -x "$command_path" ]] || fail "$command_name is not executable"
    grep -Fq '# info:' "$command_path" || fail "$command_name lacks info header"
    grep -Fq '# options:' "$command_path" || fail "$command_name lacks options header"
    grep -Fq 'func/vx/migration/main.sh' "$command_path" \
        || fail "$command_name is not a thin migration adapter"
done

# shellcheck source=func/vx/migration/transport.sh
source "$repo_root/func/vx/migration/transport.sh"
# shellcheck source=func/vx/migration/archive.sh
source "$repo_root/func/vx/migration/archive.sh"

vx_migration_validate_target root@example.test \
    || fail 'valid SSH target rejected'
! vx_migration_validate_target operator@example.test \
    || fail 'non-root SSH target accepted'
! vx_migration_validate_target 'root@example.test;id' \
    || fail 'shell metacharacter accepted in target'
vx_migration_validate_port 22 || fail 'valid SSH port rejected'
! vx_migration_validate_port 0 || fail 'zero SSH port accepted'
! vx_migration_validate_port 65536 || fail 'oversized SSH port accepted'
vx_migration_validate_identity - || fail 'OpenSSH prompt identity rejected'
! vx_migration_validate_identity "$fixture/missing" \
    || fail 'missing identity file accepted'

mkdir -p "$fixture/safe"
printf 'ok\n' >"$fixture/safe/file"
tar -C "$fixture" -czf "$fixture/safe.tar.gz" safe
vx_migration_archive_members_safe "$fixture/safe.tar.gz" \
    || fail 'safe archive rejected'
tar -C "$fixture" -czf "$fixture/traversal.tar.gz" \
    --transform='s#safe/file#../escape#' safe/file
! vx_migration_archive_members_safe "$fixture/traversal.tar.gz" \
    || fail 'archive traversal accepted'
ln -s file "$fixture/safe/link"
tar -C "$fixture" -czf "$fixture/link.tar.gz" safe
! vx_migration_archive_members_safe "$fixture/link.tar.gz" \
    || fail 'outer archive symlink accepted'

settings_vesta="$fixture/settings-vesta"
mkdir -p "$settings_vesta/conf"
cat >"$settings_vesta/conf/vesta.conf" <<'EOF'
WEB_SYSTEM='nginx'
LANGUAGE='en'
BACKUP='/environment-specific/path'
FILEMANAGER_KEY='secret-value'
EOF
VESTA="$settings_vesta" vx_migration_host_vesta_settings \
    "$fixture/vesta-settings.conf"
grep -Fqx "WEB_SYSTEM='nginx'" "$fixture/vesta-settings.conf" \
    || fail 'safe Vesta setting was not selected'
grep -Fqx "LANGUAGE='en'" "$fixture/vesta-settings.conf" \
    || fail 'language setting was not selected'
! grep -Eq 'BACKUP=|FILEMANAGER_KEY=' "$fixture/vesta-settings.conf" \
    || fail 'external path or secret Vesta setting was selected'

# Exercise the user receiver against a fixture Vesta installation. This proves
# checksum, schema, native restore, rebuild, normalization, and counter flow.
if (( EUID == 0 )) && [[ -r /etc/debian_version ]]; then
fake_vesta="$fixture/vesta"
fake_payload="$fixture/receiver-payload"
mkdir -p "$fake_vesta/bin" "$fake_vesta/data/users" \
    "$fake_payload/native/vesta"
calls="$fixture/receiver-calls"
printf "PACKAGE='default'\n" >"$fake_payload/native/vesta/user.conf"
tar -C "$fake_payload/native" -cf "$fake_payload/user-backup.tar" .
printf 'alice.2026-08-17_12-00-00.tar\n' >"$fake_payload/backup-name"
printf 'SCHEMA=1\nMODE=user\nUSER=alice\nSOURCE_DEBIAN_MAJOR=%s\nCREATED_AT=2026-08-17T00:00:00Z\n' \
    "$(cut -d. -f1 </etc/debian_version)" >"$fake_payload/metadata.conf"
(cd "$fake_payload" && sha256sum metadata.conf backup-name user-backup.tar \
    >SHA256SUMS)
receiver_archive="$fixture/receiver-user.tar.gz"
tar -C "$fake_payload" -czf "$receiver_archive" .
(cd "$fixture" && sha256sum "$(basename "$receiver_archive")") \
    >"$receiver_archive.sha256"

for fake_command in v-restore-user v-rebuild-user v-normalize-restored-user \
    v-update-user-counters v-update-sys-ip-counters; do
    cat >"$fake_vesta/bin/$fake_command" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' '$fake_command' "\$*" >>'$calls'
EOF
    chmod 0755 "$fake_vesta/bin/$fake_command"
done
cat >"$fake_vesta/bin/v-list-dns-domains" <<EOF
#!/usr/bin/env bash
printf 'example.test\n'
EOF
chmod 0755 "$fake_vesta/bin/v-list-dns-domains"

VESTA="$fake_vesta" "$repo_root/func/vx/migration/receive.sh" user \
    "$receiver_archive" "$receiver_archive.sha256" no yes >/dev/null
grep -Fq 'v-restore-user alice alice.2026-08-17_12-00-00.tar' "$calls" \
    || fail 'receiver did not invoke native user restore'
grep -Fq 'v-rebuild-user alice no' "$calls" \
    || fail 'receiver did not rebuild restored user'
grep -Fq 'v-normalize-restored-user alice' "$calls" \
    || fail 'receiver did not normalize restored user'

cp "$receiver_archive.sha256" "$fixture/bad.sha256"
sed -i 's/^[a-f0-9]/z/' "$fixture/bad.sha256"
if VESTA="$fake_vesta" "$repo_root/func/vx/migration/receive.sh" user \
    "$receiver_archive" "$fixture/bad.sha256" no yes >/dev/null 2>&1; then
    fail 'receiver accepted an invalid outer checksum'
fi
fi

grep -Fq 'ControlMaster=auto' "$repo_root/func/vx/migration/transport.sh" \
    || fail 'SSH control connection missing'
grep -Fq 'StrictHostKeyChecking=accept-new' \
    "$repo_root/func/vx/migration/transport.sh" \
    || fail 'SSH host-key policy missing'
grep -Fq 'SOURCE_DEBIAN_MAJOR' "$repo_root/func/vx/migration/receive.sh" \
    || fail 'Debian compatibility gate missing'
grep -Fq 'target contains non-admin Vesta users' \
    "$repo_root/func/vx/migration/receive.sh" \
    || fail 'host target user protection missing'
grep -Fq 'target Vesta user already exists' \
    "$repo_root/func/vx/migration/receive.sh" \
    || fail 'user collision protection missing'

if rg -n -i '(jackpridham|vortex-scripts|sydvortex|\.vxapp\.io|\.jackpridham\.com|/mnt/nfs|rrsync)' \
    "$repo_root/bin/v-migrate-host" \
    "$repo_root/bin/v-migrate-user" \
    "$repo_root/func/vx/migration" \
    "$repo_root/.docs/contracts/host-user-migration.md" \
    "$repo_root/.docs/user-guides/host-user-migration.md"; then
    fail 'external ecosystem or environment-specific reference found'
fi

echo 'Host and user migration tests passed.'
