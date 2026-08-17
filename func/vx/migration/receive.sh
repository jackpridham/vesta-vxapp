#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
VESTA=${VESTA:-/usr/local/vesta}
export VESTA

mode=${1-}
archive=${2-}
checksum_file=${3-}
force=${4-no}
normalize=${5-yes}
work_root=

receiver_fail() {
    echo "Error: $1" >&2
    exit "${2:-1}"
}

receiver_cleanup() {
    [[ -n "$work_root" ]] && rm -rf -- "$work_root"
}
trap receiver_cleanup EXIT INT TERM

receiver_metadata_value() {
    local file=$1
    local key=$2
    local value
    value=$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' \
        "$file")
    [[ "$value" =~ ^[A-Za-z0-9_.:@+-]*$ ]] || return 1
    printf '%s\n' "$value"
}

receiver_archive_paths_safe() {
    local input=$1
    local member members
    members=$(tar -tzf "$input") || return 1
    while IFS= read -r member; do
        [[ -n "$member" && "$member" != /* ]] || return 1
        case "/$member/" in
            */../*) return 1 ;;
        esac
    done <<<"$members"
}

receiver_outer_archive_safe() {
    local input=$1
    local type types
    receiver_archive_paths_safe "$input" || return 1
    types=$(tar -tvzf "$input" | cut -c1) || return 1
    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done <<<"$types"
}

receiver_verify_outer_checksum() {
    local expected_name=$1
    local expected_hash extra
    read -r expected_hash expected_name <"$checksum_file" || return 1
    read -r extra < <(sed -n '2p' "$checksum_file") || :
    [[ -z "$extra" && "$expected_name" == "$(basename "$archive")" \
        && "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$expected_hash" ]]
}

receiver_verify_payload() {
    local payload=$1
    local expected=$2
    local actual
    actual=$(LC_ALL=C awk '{print $2}' "$payload/SHA256SUMS" \
        | sed 's#^\*##' | LC_ALL=C sort)
    expected=$(printf '%s\n' "$expected" | LC_ALL=C sort)
    [[ "$actual" == "$expected" ]] || return 1
    (cd "$payload" && sha256sum -c SHA256SUMS >/dev/null)
}

receiver_archive_prefix_only() {
    local input=$1
    local prefix=$2
    local member members
    members=$(tar -tzf "$input") || return 1
    while IFS= read -r member; do
        member=${member#./}
        [[ "$member" == "$prefix" || "$member" == "$prefix/"* ]] || return 1
    done <<<"$members"
}

receiver_available_packages_install() {
    local package available_file="$work_root/available-packages"
    : >"$available_file"
    while IFS= read -r package; do
        [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || continue
        if apt-cache show "$package" >/dev/null 2>&1; then
            printf '%s\n' "$package" >>"$available_file"
        else
            echo "Warning: source package is unavailable on target: $package" >&2
        fi
    done <"$work_root/payload/packages.txt"
    if [[ -s "$available_file" ]]; then
        DEBIAN_FRONTEND=noninteractive xargs -r apt-get install -y \
            --no-install-recommends <"$available_file"
    fi
}

receiver_assert_no_web_restore_errors() {
    local username=$1
    if find "/home/$username/web" -type f -name restore_errors.log \
        -size +0c -print -quit 2>/dev/null | grep -q .; then
        receiver_fail "native Vesta restore reported website extraction errors"
    fi
}

receiver_restore_native_user() {
    local username=$1
    local payload=$2
    local stored_name backup_path
    stored_name=$(<"$payload/backup-name")
    [[ "$stored_name" =~ ^${username}\.[0-9]{4}-[0-9]{2}-[0-9]{2}(_[0-9]{2}-[0-9]{2}-[0-9]{2})?\.tar$ ]] \
        || receiver_fail "invalid native Vesta backup name"
    backup_path="$payload/$stored_name"
    cp -- "$payload/user-backup.tar" "$backup_path"
    chmod 0600 "$backup_path"
    (umask 022
        OVERRIDE_BACKUP_PATH="$payload" BACKUP_TEMP="$work_root" \
            "$VESTA/bin/v-restore-user" "$username" "$stored_name")
    receiver_assert_no_web_restore_errors "$username"
    "$VESTA/bin/v-rebuild-user" "$username" no
    if [[ "$normalize" == yes \
        && -n "$("$VESTA/bin/v-list-dns-domains" "$username" plain 2>/dev/null)" ]]; then
        "$VESTA/bin/v-normalize-restored-user" "$username"
    fi
    "$VESTA/bin/v-update-user-counters" "$username"
    "$VESTA/bin/v-update-sys-ip-counters"
}

receiver_restore_admin() {
    local payload=$1
    local stored_name backup_path admin_conf
    stored_name=$(<"$payload/admin-backup-name")
    [[ "$stored_name" =~ ^admin\.[0-9]{4}-[0-9]{2}-[0-9]{2}(_[0-9]{2}-[0-9]{2}-[0-9]{2})?\.tar$ ]] \
        || receiver_fail "invalid admin backup name"
    backup_path="$payload/$stored_name"
    cp -- "$payload/admin-backup.tar" "$backup_path"
    chmod 0600 "$backup_path"
    (umask 022
        OVERRIDE_BACKUP_PATH="$payload" BACKUP_TEMP="$work_root" \
            "$VESTA/bin/v-restore-user" admin "$stored_name")
    receiver_assert_no_web_restore_errors admin

    admin_conf="$work_root/admin-user.conf"
    tar -xOf "$payload/admin-backup.tar" ./vesta/user.conf >"$admin_conf"
    install -o root -g admin -m 0660 "$admin_conf" \
        "$VESTA/data/users/admin/user.conf"
    "$VESTA/bin/v-rebuild-user" admin no
    if [[ -n "$("$VESTA/bin/v-list-dns-domains" admin plain 2>/dev/null)" ]]; then
        "$VESTA/bin/v-normalize-restored-user" admin || \
            echo "Warning: admin DNS normalization did not complete" >&2
    fi
    "$VESTA/bin/v-update-user-counters" admin
    "$VESTA/bin/v-update-sys-ip-counters"
}

receiver_installer_value() {
    local key=$1
    local value
    value=$(receiver_metadata_value "$work_root/payload/installer.conf" "$key") \
        || receiver_fail "invalid installer field $key"
    printf '%s\n' "$value"
}

receiver_apply_vesta_settings() {
    local settings=$1
    local target="$VESTA/conf/vesta.conf"
    local line key temporary
    local setting_pattern="^([A-Z_]+)='[^']*'$"
    local allowed_settings='WEB_SYSTEM WEB_RGROUPS WEB_PORT WEB_SSL WEB_SSL_PORT WEB_BACKEND PROXY_SYSTEM PROXY_PORT PROXY_SSL_PORT FTP_SYSTEM MAIL_SYSTEM IMAP_SYSTEM ANTIVIRUS_SYSTEM ANTISPAM_SYSTEM DB_SYSTEM DNS_SYSTEM STATS_SYSTEM CRON_SYSTEM DISK_QUOTA FIREWALL_SYSTEM FIREWALL_EXTENSION LANGUAGE BACKUP_GZIP MAIL_URL DB_PMA_URL DB_PGA_URL SOFTACULOUS MAX_DBUSER_LEN DISABLE_IP_CHECK'
    [[ -f "$target" && ! -L "$target" ]] \
        || receiver_fail "target vesta.conf is unavailable"
    while IFS= read -r line; do
        [[ "$line" =~ $setting_pattern ]] \
            || receiver_fail "invalid transferred Vesta setting"
        key=${BASH_REMATCH[1]}
        [[ " $allowed_settings " == *" $key "* ]] \
            || receiver_fail "unapproved transferred Vesta setting: $key"
        temporary=$(mktemp "$VESTA/conf/.vesta.conf.migration.XXXXXX") \
            || receiver_fail "cannot stage vesta.conf update"
        awk -v key="$key" -v replacement="$line" '
            index($0, key "=") == 1 { $0 = replacement; found = 1 }
            { print }
            END { if (!found) print replacement }
        ' "$target" >"$temporary"
        chown --reference="$target" "$temporary"
        chmod --reference="$target" "$temporary"
        mv -f -- "$temporary" "$target"
    done <"$settings"
}

receiver_install_vesta() {
    local payload=$1
    local installer release
    release=$(cut -d. -f1 </etc/debian_version)

    tar -C / -xzf "$payload/vesta-tree.tar.gz"
    installer="$VESTA/install/vst-install-debian.sh"
    [[ -x "$installer" || -f "$installer" ]] \
        || receiver_fail "transferred Vesta installer is missing"

    /bin/bash "$installer" \
        --interactive no \
        --apache "$(receiver_installer_value APACHE)" \
        --nginx "$(receiver_installer_value NGINX)" \
        --phpfpm "$(receiver_installer_value PHPFPM)" \
        --vsftpd "$(receiver_installer_value VSFTPD)" \
        --proftpd "$(receiver_installer_value PROFTPD)" \
        --named "$(receiver_installer_value NAMED)" \
        --mysql "$(receiver_installer_value MYSQL)" \
        --postgresql "$(receiver_installer_value POSTGRESQL)" \
        --exim "$(receiver_installer_value EXIM)" \
        --dovecot "$(receiver_installer_value DOVECOT)" \
        --clamav "$(receiver_installer_value CLAMAV)" \
        --spamassassin "$(receiver_installer_value SPAMASSASSIN)" \
        --iptables "$(receiver_installer_value IPTABLES)" \
        --fail2ban "$(receiver_installer_value FAIL2BAN)" \
        --quota "$(receiver_installer_value QUOTA)" \
        --lang "$(receiver_installer_value LANGUAGE)" \
        --hostname "$(hostname -f)" \
        --email "admin@$(hostname -f)"

    [[ -x "$VESTA/bin/v-restore-user" ]] \
        || receiver_fail "Vesta installation did not provide restore commands"
    echo "Vesta prerequisites installed for Debian $release."
}

receiver_apply_host() {
    local payload=$1
    local non_admin_users=

    if [[ -d "$VESTA/data/users" ]]; then
        non_admin_users=$(find "$VESTA/data/users" -mindepth 1 -maxdepth 1 \
            -type d ! -name admin -printf '%f\n')
    fi
    [[ -z "$non_admin_users" ]] \
        || receiver_fail "target contains non-admin Vesta users; host migration refused"

    if [[ -x "$VESTA/bin/v-list-users" ]]; then
        [[ "$force" == yes ]] \
            || receiver_fail "Vesta is already installed; rerun with FORCE=yes after review"
        mkdir -p /var/backups
        tar -C / -czf "/var/backups/vesta-pre-migration-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
            usr/local/vesta etc/nginx etc/apache2 etc/php 2>/dev/null || :
    else
        [[ ! -e "$VESTA" && ! $(id -u admin 2>/dev/null) ]] \
            || receiver_fail "target is not clean enough for unattended Vesta installation"
        receiver_install_vesta "$payload"
    fi

    apt-get update
    receiver_available_packages_install
    tar -C / -xzf "$payload/vesta-tree.tar.gz"
    tar -C / -xzf "$payload/host-config.tar.gz"
    receiver_apply_vesta_settings "$payload/vesta-settings.conf"
    receiver_restore_admin "$payload"

    "$VESTA/bin/v-sync-docker-shell-access-all" 2>/dev/null || :
    "$VESTA/bin/v-restart-web-backend" 2>/dev/null || :
    "$VESTA/bin/v-restart-web" 2>/dev/null || :
    "$VESTA/bin/v-restart-proxy" 2>/dev/null || :
    [[ -x "$VESTA/bin/v-list-users" ]] \
        || receiver_fail "target Vesta command verification failed"
}

[[ $(id -u) -eq 0 ]] || receiver_fail "receiver must run as root"
[[ "$mode" == host || "$mode" == user ]] || receiver_fail "invalid migration mode"
[[ "$force" == yes || "$force" == no ]] || receiver_fail "invalid force value"
[[ "$normalize" == yes || "$normalize" == no ]] || receiver_fail "invalid normalize value"
[[ -f "$archive" && ! -L "$archive" && -f "$checksum_file" \
    && ! -L "$checksum_file" ]] || receiver_fail "migration payload is missing"
receiver_verify_outer_checksum "$(basename "$archive")" \
    || receiver_fail "migration archive checksum mismatch"
receiver_outer_archive_safe "$archive" \
    || receiver_fail "unsafe migration archive structure"

work_root=$(mktemp -d /var/tmp/vesta-migration-receive.XXXXXX) \
    || receiver_fail "cannot create target work directory"
chmod 0711 "$work_root" \
    || receiver_fail "cannot make target work directory traversable"
mkdir -p "$work_root/payload"
tar -C "$work_root/payload" -xzf "$archive"

schema=$(receiver_metadata_value "$work_root/payload/metadata.conf" SCHEMA) \
    || receiver_fail "invalid migration metadata"
archive_mode=$(receiver_metadata_value "$work_root/payload/metadata.conf" MODE) \
    || receiver_fail "invalid migration mode metadata"
username=$(receiver_metadata_value "$work_root/payload/metadata.conf" USER) \
    || receiver_fail "invalid migration user metadata"
source_major=$(receiver_metadata_value "$work_root/payload/metadata.conf" SOURCE_DEBIAN_MAJOR) \
    || receiver_fail "invalid source OS metadata"
target_major=$(cut -d. -f1 </etc/debian_version 2>/dev/null) \
    || receiver_fail "target must run Debian"
[[ "$schema" == 1 && "$archive_mode" == "$mode" ]] \
    || receiver_fail "unsupported migration schema"
[[ "$source_major" == "$target_major" ]] \
    || receiver_fail "source and target Debian major versions differ"

if [[ "$mode" == user ]]; then
    expected_files=$'backup-name\nmetadata.conf\nuser-backup.tar'
    receiver_verify_payload "$work_root/payload" "$expected_files" \
        || receiver_fail "user payload manifest verification failed"
    [[ "$username" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ && "$username" != admin ]] \
        || receiver_fail "invalid or forbidden migration user"
    [[ -x "$VESTA/bin/v-restore-user" ]] \
        || receiver_fail "target must already have Vesta installed"
    [[ ! -d "$VESTA/data/users/$username" ]] \
        || receiver_fail "target Vesta user already exists"
    receiver_restore_native_user "$username" "$work_root/payload"
else
    expected_files=$'admin-backup-name\nadmin-backup.tar\nhost-config.tar.gz\ninstaller.conf\nmetadata.conf\npackages.txt\nvesta-settings.conf\nvesta-tree.tar.gz'
    receiver_verify_payload "$work_root/payload" "$expected_files" \
        || receiver_fail "host payload manifest verification failed"
    receiver_archive_paths_safe "$work_root/payload/vesta-tree.tar.gz" \
        || receiver_fail "unsafe Vesta application archive"
    receiver_archive_prefix_only "$work_root/payload/vesta-tree.tar.gz" \
        usr/local/vesta || receiver_fail "Vesta archive escaped its install root"
    receiver_archive_paths_safe "$work_root/payload/host-config.tar.gz" \
        || receiver_fail "unsafe host configuration archive"
    receiver_archive_prefix_only "$work_root/payload/host-config.tar.gz" \
        etc || receiver_fail "host configuration escaped /etc"
    receiver_apply_host "$work_root/payload"
fi

echo "Target $mode migration completed successfully."
