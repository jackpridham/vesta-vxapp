#!/usr/bin/env bash

vx_migration_debian_major() {
    [[ -r /etc/debian_version ]] || return 1
    cut -d. -f1 </etc/debian_version
}

vx_migration_archive_members_safe() {
    local archive=$1
    local member type members types

    members=$(tar -tzf "$archive") || return 1
    while IFS= read -r member; do
        [[ -n "$member" && "$member" != /* ]] || return 1
        case "/$member/" in
            */../*) return 1 ;;
        esac
    done <<<"$members"

    types=$(tar -tvzf "$archive" | cut -c1) || return 1
    while IFS= read -r type; do
        case "$type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done <<<"$types"
}

vx_migration_write_metadata() {
    local destination=$1
    local mode=$2
    local username=${3-}
    local schema=${4-1}
    local source_major
    source_major=$(vx_migration_debian_major) || return 1

    {
        printf 'SCHEMA=%s\n' "$schema"
        printf 'MODE=%s\n' "$mode"
        printf 'USER=%s\n' "$username"
        printf 'SOURCE_DEBIAN_MAJOR=%s\n' "$source_major"
        printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$destination"
    chmod 0600 "$destination"
}

vx_migration_create_native_user_backup() {
    local username=$1
    local destination=$2
    local before newest

    before=$(find "$destination" -maxdepth 1 -type f \
        -name "$username.*.tar" -printf '%f\n' | sort)
    OVERRIDE_BACKUP_PATH="$destination" NOW=yes \
        "$VESTA/bin/v-backup-user" "$username" no >&2
    newest=$(comm -13 <(printf '%s\n' "$before") \
        <(find "$destination" -maxdepth 1 -type f \
            -name "$username.*.tar" -printf '%f\n' | sort) | tail -n1)
    if [[ -z "$newest" ]]; then
        newest=$(find "$destination" -maxdepth 1 -type f \
            -name "$username.*.tar" -printf '%T@ %f\n' | sort -nr \
            | awk 'NR == 1 {print $2}')
    fi
    [[ -n "$newest" && -f "$destination/$newest" ]] || {
        echo "Error: Vesta backup completed without a discoverable archive" >&2
        return 1
    }
    printf '%s\n' "$newest"
}

vx_migration_create_user_bundle() {
    local username=$1
    local stage=$2
    local payload="$stage/payload"
    local backup_name archive web_domains

    mkdir -p "$payload"
    chmod 0700 "$payload"
    vx_migration_write_metadata "$payload/metadata.conf" user "$username" 2
    web_domains=$("$VESTA/bin/v-list-web-domains" "$username" plain) \
        || return 1
    printf '%s\n' "$web_domains" \
        | awk -F '\t' 'NF >= 2 && $2 != "" {print $2}' \
        | LC_ALL=C sort -u >"$payload/source-web-ips"
    backup_name=$(vx_migration_create_native_user_backup "$username" "$payload") \
        || return 1
    mv -- "$payload/$backup_name" "$payload/user-backup.tar"
    printf '%s\n' "$backup_name" >"$payload/backup-name"
    (cd "$payload" && sha256sum metadata.conf backup-name source-web-ips \
        user-backup.tar >SHA256SUMS)
    archive="$stage/vesta-user-$username-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    tar -C "$payload" -czf "$archive" .
    (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")") \
        >"$archive.sha256"
    printf '%s\n' "$archive"
}

vx_migration_host_package_manifest() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 2>/dev/null \
        | awk '$2 == "ii" {print $1}' \
        | sed 's/:.*$//' \
        | grep -E '^(vesta($|-)|nginx|apache2|libapache2-|php([0-9.]|$)|mariadb-|mysql-|postgresql|bind9|exim4|dovecot-|clamav-|spamassassin|spamd|proftpd|vsftpd|fail2ban|roundcube|phpmyadmin|docker|docker-compose|jq|age|expect|rrdtool|quota)' \
        | sort -u
}

vx_migration_host_installer_config() {
    local destination=$1
    # shellcheck disable=SC1090
    source "$VESTA/conf/vesta.conf"
    {
        printf 'APACHE=%s\n' "$([[ "${WEB_BACKEND:-}" == apache2 ]] && echo yes || echo no)"
        printf 'NGINX=%s\n' "$([[ "${PROXY_SYSTEM:-}${WEB_SYSTEM:-}" == *nginx* ]] && echo yes || echo no)"
        printf 'PHPFPM=%s\n' "$([[ "${WEB_BACKEND:-}" == *php-fpm* || "${WEB_SYSTEM:-}" == *php-fpm* ]] && echo yes || echo no)"
        printf 'VSFTPD=%s\n' "$([[ "${FTP_SYSTEM:-}" == vsftpd ]] && echo yes || echo no)"
        printf 'PROFTPD=%s\n' "$([[ "${FTP_SYSTEM:-}" == proftpd ]] && echo yes || echo no)"
        printf 'NAMED=%s\n' "$([[ -n "${DNS_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'MYSQL=%s\n' "$([[ "${DB_SYSTEM:-}" == *mysql* ]] && echo yes || echo no)"
        printf 'POSTGRESQL=%s\n' "$([[ "${DB_SYSTEM:-}" == *pgsql* ]] && echo yes || echo no)"
        printf 'EXIM=%s\n' "$([[ -n "${MAIL_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'DOVECOT=%s\n' "$([[ -n "${IMAP_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'CLAMAV=%s\n' "$([[ -n "${ANTIVIRUS_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'SPAMASSASSIN=%s\n' "$([[ -n "${ANTISPAM_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'IPTABLES=%s\n' "$([[ -n "${FIREWALL_SYSTEM:-}" ]] && echo yes || echo no)"
        printf 'FAIL2BAN=%s\n' "$([[ "${FIREWALL_EXTENSION:-}" == *fail2ban* ]] && echo yes || echo no)"
        printf 'QUOTA=%s\n' "${DISK_QUOTA:-no}"
        printf 'LANGUAGE=%s\n' "${LANGUAGE:-en}"
    } >"$destination"
}

vx_migration_host_vesta_settings() {
    local destination=$1
    local key line
    local setting_pattern="^[A-Z_]+='[^']*'$"
    : >"$destination"
    for key in \
        WEB_SYSTEM WEB_RGROUPS WEB_PORT WEB_SSL WEB_SSL_PORT WEB_BACKEND \
        PROXY_SYSTEM PROXY_PORT PROXY_SSL_PORT FTP_SYSTEM MAIL_SYSTEM \
        IMAP_SYSTEM ANTIVIRUS_SYSTEM ANTISPAM_SYSTEM DB_SYSTEM DNS_SYSTEM \
        STATS_SYSTEM CRON_SYSTEM DISK_QUOTA FIREWALL_SYSTEM \
        FIREWALL_EXTENSION LANGUAGE BACKUP_GZIP MAIL_URL DB_PMA_URL \
        DB_PGA_URL SOFTACULOUS MAX_DBUSER_LEN DISABLE_IP_CHECK; do
        line=$(grep -m1 "^${key}='" "$VESTA/conf/vesta.conf" 2>/dev/null || :)
        [[ "$line" =~ $setting_pattern ]] && printf '%s\n' "$line" >>"$destination"
    done
    return 0
}

vx_migration_create_host_config_archive() {
    local destination=$1
    local -a paths=()
    local path
    for path in \
        etc/nginx etc/apache2 etc/php etc/mysql etc/postgresql \
        etc/exim4 etc/dovecot etc/bind etc/fail2ban etc/proftpd \
        etc/vsftpd.conf etc/roundcube etc/phpmyadmin \
        etc/logrotate.d/vesta etc/cron.d/vesta; do
        [[ -e "/$path" && ! -L "/$path" ]] && paths+=("$path")
    done
    if ((${#paths[@]})); then
        tar -C / -czf "$destination" --one-file-system "${paths[@]}"
    else
        tar -czf "$destination" --files-from /dev/null
    fi
}

vx_migration_create_host_bundle() {
    local stage=$1
    local payload="$stage/payload"
    local admin_backup archive

    mkdir -p "$payload"
    chmod 0700 "$payload"
    vx_migration_write_metadata "$payload/metadata.conf" host admin
    vx_migration_host_installer_config "$payload/installer.conf"
    vx_migration_host_vesta_settings "$payload/vesta-settings.conf"
    vx_migration_host_package_manifest >"$payload/packages.txt"
    tar -C /usr/local -czf "$payload/vesta-tree.tar.gz" \
        --exclude='vesta/conf' \
        --exclude='vesta/ssl' \
        --exclude='vesta/data/users' \
        --exclude='vesta/data/ips' \
        --exclude='vesta/data/firewall' \
        --exclude='vesta/data/queue' \
        --exclude='vesta/data/sessions' \
        --exclude='vesta/data/tmp' \
        --exclude='vesta/log' \
        --exclude='vesta/.git' vesta
    vx_migration_create_host_config_archive "$payload/host-config.tar.gz"
    admin_backup=$(vx_migration_create_native_user_backup admin "$payload") \
        || return 1
    mv -- "$payload/$admin_backup" "$payload/admin-backup.tar"
    printf '%s\n' "$admin_backup" >"$payload/admin-backup-name"
    (cd "$payload" && sha256sum metadata.conf installer.conf \
        vesta-settings.conf packages.txt \
        vesta-tree.tar.gz host-config.tar.gz admin-backup.tar \
        admin-backup-name >SHA256SUMS)
    archive="$stage/vesta-host-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    tar -C "$payload" -czf "$archive" .
    (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")") \
        >"$archive.sha256"
    printf '%s\n' "$archive"
}
