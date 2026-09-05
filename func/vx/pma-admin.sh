#!/usr/bin/env bash

# Vortex-owned phpMyAdmin administrator support.

vx_pma_credentials_root() {
    printf '%s\n' "$VESTA/data/vx/pma-admin"
}

vx_pma_credentials_file() {
    printf '%s/credentials.conf\n' "$(vx_pma_credentials_root)"
}

vx_pma_set_error() {
    # Consumed by the public Vesta adapter after a helper returns non-zero.
    # shellcheck disable=SC2034
    VX_PMA_ERROR=$1
    return 1
}

vx_pma_mysql_execute() {
    /usr/bin/mysql --protocol=socket --user=root --batch --raw "$@"
}

vx_pma_check_connection() {
    printf 'SELECT 1;\n' | vx_pma_mysql_execute >/dev/null 2>&1 \
        || vx_pma_set_error 'could not connect to MySQL as root through the local socket'
}

vx_pma_server_version() {
    local version

    version=$(printf 'SELECT VERSION();\n' \
        | vx_pma_mysql_execute --skip-column-names 2>/dev/null) || return 1
    version=${version%%$'\n'*}
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

vx_pma_generate_password() {
    local password

    password=$(/usr/bin/od -An -N18 -tx1 /dev/urandom 2>/dev/null \
        | /usr/bin/tr -d ' \n') || return 1
    [[ "$password" =~ ^[[:xdigit:]]{36}$ ]] || return 1
    printf '%s\n' "$password"
}

vx_pma_store_credentials() {
    local password=$1
    local credentials_root credentials_file temporary_file
    local -a install_arguments=(-d -m 0700)

    credentials_root=$(vx_pma_credentials_root)
    credentials_file=$(vx_pma_credentials_file)
    if [[ $EUID -eq 0 ]]; then
        install_arguments+=(-o root -g root)
    fi
    /usr/bin/install "${install_arguments[@]}" "$credentials_root" \
        || vx_pma_set_error 'could not prepare the phpMyAdmin administrator state directory' \
        || return 1
    temporary_file=$(/usr/bin/mktemp "$credentials_root/.credentials.XXXXXX") \
        || vx_pma_set_error 'could not stage phpMyAdmin administrator credentials' \
        || return 1

    if ! {
        /usr/bin/printf 'username=pma_admin\n'
        builtin printf 'password=%s\n' "$password"
        /usr/bin/printf 'updated=%s\n' "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary_file"; then
        /usr/bin/rm -f -- "$temporary_file"
        vx_pma_set_error 'could not write phpMyAdmin administrator credentials'
        return 1
    fi

    if [[ $EUID -eq 0 ]]; then
        /usr/bin/chown root:root "$temporary_file" || {
            /usr/bin/rm -f -- "$temporary_file"
            vx_pma_set_error 'could not secure phpMyAdmin administrator credentials'
            return 1
        }
    fi
    /usr/bin/chmod 0600 "$temporary_file" \
        && /usr/bin/mv -f -- "$temporary_file" "$credentials_file" || {
        /usr/bin/rm -f -- "$temporary_file"
        vx_pma_set_error 'could not install phpMyAdmin administrator credentials'
        return 1
    }
}

vx_pma_create_admin() {
    local password sql

    password=$(vx_pma_generate_password) \
        || vx_pma_set_error 'could not generate a phpMyAdmin administrator password' \
        || return 1
    sql="CREATE USER IF NOT EXISTS 'pma_admin'@'localhost' IDENTIFIED BY '$password';
ALTER USER 'pma_admin'@'localhost' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON *.* TO 'pma_admin'@'localhost' WITH GRANT OPTION;"

    printf '%s\n' "$sql" | vx_pma_mysql_execute >/dev/null 2>&1 \
        || vx_pma_set_error 'could not create pma_admin@localhost' \
        || return 1
    vx_pma_store_credentials "$password" || return 1
    unset password sql
}

vx_pma_read_control_credentials() {
    local config_file=${1-/etc/phpmyadmin/config.inc.php}
    local encoded output
    local -a fields

    [[ -x /usr/bin/php ]] || return 2
    [[ -r "$config_file" ]] || return 2
    output=$(/usr/bin/php -d display_errors=0 -r '
        require $argv[1];
        foreach (($cfg["Servers"] ?? []) as $server) {
            if (!is_array($server) || empty($server["controluser"]) ||
                !isset($server["controlpass"]) ||
                !is_string($server["controlpass"]) ||
                $server["controlpass"] === "" || empty($server["pmadb"])) {
                continue;
            }
            echo base64_encode((string) $server["controluser"]), "\n";
            echo base64_encode((string) $server["controlpass"]), "\n";
            echo base64_encode((string) $server["pmadb"]), "\n";
            exit(0);
        }
        exit(2);
    ' "$config_file" 2>/dev/null)
    case $? in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac

    mapfile -t fields <<<"$output"
    [[ ${#fields[@]} -eq 3 ]] || return 1
    for encoded in "${fields[@]}"; do
        [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
    done
    VX_PMA_CONTROL_USER=$(printf '%s' "${fields[0]}" | /usr/bin/base64 --decode) \
        || return 1
    VX_PMA_CONTROL_PASSWORD=$(printf '%s' "${fields[1]}" | /usr/bin/base64 --decode) \
        || return 1
    VX_PMA_CONTROL_DATABASE=$(printf '%s' "${fields[2]}" | /usr/bin/base64 --decode) \
        || return 1

    [[ "$VX_PMA_CONTROL_USER" =~ ^[A-Za-z0-9_.-]{1,80}$ ]] || return 1
    [[ "$VX_PMA_CONTROL_DATABASE" =~ ^[A-Za-z0-9_]{1,64}$ ]] || return 1
}

vx_pma_reconcile_control_user() {
    local config_file=${1-/etc/phpmyadmin/config.inc.php}
    local account_sql password_base64 server_version sql

    vx_pma_read_control_credentials "$config_file"
    case $? in
        0) ;;
        2) return 2 ;;
        *) vx_pma_set_error 'could not read phpMyAdmin control-user credentials'; return 1 ;;
    esac

    password_base64=$(printf '%s' "$VX_PMA_CONTROL_PASSWORD" | /usr/bin/base64 -w 0) \
        || vx_pma_set_error 'could not encode the phpMyAdmin control-user password' \
        || return 1
    server_version=$(vx_pma_server_version) \
        || vx_pma_set_error 'could not determine the MySQL server version' \
        || return 1
    if [[ "$server_version" == *MariaDB* ]]; then
        account_sql="SET @vx_create = CONCAT('CREATE OR REPLACE USER ''$VX_PMA_CONTROL_USER''@''localhost'' IDENTIFIED BY ', QUOTE(@vx_password));
PREPARE vx_statement FROM @vx_create;
EXECUTE vx_statement;
DEALLOCATE PREPARE vx_statement;"
    else
        account_sql="SET @vx_create = CONCAT('CREATE USER IF NOT EXISTS ''$VX_PMA_CONTROL_USER''@''localhost'' IDENTIFIED BY ', QUOTE(@vx_password));
PREPARE vx_statement FROM @vx_create;
EXECUTE vx_statement;
DEALLOCATE PREPARE vx_statement;
SET @vx_alter = CONCAT('ALTER USER ''$VX_PMA_CONTROL_USER''@''localhost'' IDENTIFIED BY ', QUOTE(@vx_password));
PREPARE vx_statement FROM @vx_alter;
EXECUTE vx_statement;
DEALLOCATE PREPARE vx_statement;"
    fi
    sql="SET @vx_password = FROM_BASE64('$password_base64');
$account_sql
GRANT ALL PRIVILEGES ON \`$VX_PMA_CONTROL_DATABASE\`.* TO '$VX_PMA_CONTROL_USER'@'localhost';"

    if ! printf '%s\n' "$sql" | vx_pma_mysql_execute >/dev/null 2>&1; then
        unset VX_PMA_CONTROL_PASSWORD account_sql password_base64 server_version sql
        vx_pma_set_error 'could not reconcile the phpMyAdmin control user'
        return 1
    fi
    unset VX_PMA_CONTROL_PASSWORD account_sql password_base64 server_version sql
}

vx_pma_list_managed_databases() {
    local user_dir user db_conf line db_count=0

    printf '%-40s %-20s %-20s %-10s\n' \
        DATABASE DB_USER OWNER SUSPENDED
    printf '%-40s %-20s %-20s %-10s\n' \
        ---------------------------------------- -------------------- \
        -------------------- ----------

    for user_dir in "$VESTA"/data/users/*; do
        [[ -d "$user_dir" ]] || continue
        user=${user_dir##*/}
        db_conf=$user_dir/db.conf
        [[ -f "$db_conf" ]] || continue

        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            unset DB DBUSER TYPE SUSPENDED
            parse_object_kv_list_non_eval "$line"
            if [[ "${TYPE:-mysql}" == mysql ]]; then
                printf '%-40s %-20s %-20s %-10s\n' \
                    "${DB:-}" "${DBUSER:-}" "$user" "${SUSPENDED:-}"
                ((db_count++))
            fi
        done <"$db_conf"
    done

    printf '\nTotal managed MySQL databases: %s\n' "$db_count"
}

vx_pma_list_server_databases() {
    local output database size
    local query="SELECT s.SCHEMA_NAME,
ROUND(COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0) / 1024 / 1024, 2)
FROM information_schema.SCHEMATA s
LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
GROUP BY s.SCHEMA_NAME
ORDER BY s.SCHEMA_NAME;"

    output=$(printf '%s\n' "$query" | vx_pma_mysql_execute --skip-column-names) \
        || vx_pma_set_error 'could not list databases from the MySQL server' \
        || return 1

    printf '%-40s %-15s\n' DATABASE 'SIZE (MB)'
    printf '%-40s %-15s\n' ---------------------------------------- ---------------
    while IFS=$'\t' read -r database size; do
        [[ -n "$database" ]] || continue
        printf '%-40s %-15s\n' "$database" "$size"
    done <<<"$output"
}
