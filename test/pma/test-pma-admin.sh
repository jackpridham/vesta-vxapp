#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$test_dir/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
export VESTA="$work_root/vesta"

cleanup() {
    [[ "$work_root" == /tmp/* && -d "$work_root" ]] \
        && /usr/bin/rm -rf -- "$work_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3"
}

/usr/bin/mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" \
    "$VESTA/log"
user='admin'
REDIRECT_ERROR_TO_STDERR=0
PARSE_DOUBLE_QUOTES_VAR=''
source "$repo_root/func/main.sh"
source "$repo_root/func/vx/pma-admin.sh"

password=$(vx_pma_generate_password)
[[ "$password" =~ ^[[:xdigit:]]{36}$ ]] \
    || fail 'generated password is not 144 bits of hexadecimal data'

(
    # Intercept external printf without changing the production command path.
    /usr/bin/printf() {
        local argument
        for argument in "$@"; do
            [[ "$argument" != *"$password"* ]] \
                || fail 'administrator password exposed in external printf arguments'
        done
        command /usr/bin/printf "$@"
    }
    vx_pma_store_credentials "$password"
) || fail 'credential storage must not expose the password in process arguments'
credentials=$(vx_pma_credentials_file)
[[ "$(/usr/bin/stat -c '%a' "$credentials")" == 600 ]] \
    || fail 'credentials mode is not 0600'
[[ "$(/usr/bin/stat -c '%a' "${credentials%/*}")" == 700 ]] \
    || fail 'credentials directory mode is not 0700'
/usr/bin/grep -q "^password=$password$" "$credentials" \
    || fail 'stored credentials do not contain the generated password'

sql_log="$work_root/mysql.sql"
vx_pma_mysql_execute() {
    local input

    input=$(/usr/bin/cat)
    if [[ "$input" == 'SELECT VERSION();' ]]; then
        /usr/bin/printf '10.3.39-MariaDB\n'
    else
        /usr/bin/printf '%s\n' "$input" >>"$sql_log"
    fi
}
vx_pma_create_admin
admin_sql=$(<"$sql_log")
assert_contains "$admin_sql" "'pma_admin'@'localhost'" \
    'administrator SQL does not create a localhost account'
[[ "$admin_sql" != *"'pma_admin'@'%'"* ]] \
    || fail 'administrator SQL creates a wildcard-host account'
assert_contains "$admin_sql" 'GRANT ALL PRIVILEGES ON *.*' \
    'administrator SQL does not grant global privileges'

pma_config="$work_root/config.inc.php"
/usr/bin/printf '%s\n' '<?php' \
    '$cfg["Servers"][1]["controluser"] = "phpmyadmin";' \
    "\$cfg[\"Servers\"][1][\"controlpass\"] = \"control'secret\\\\path\";" \
    '$cfg["Servers"][1]["pmadb"] = "phpmyadmin";' >"$pma_config"
: >"$sql_log"
vx_pma_reconcile_control_user "$pma_config"
control_sql=$(<"$sql_log")
assert_contains "$control_sql" "'phpmyadmin'@'localhost'" \
    'control-user SQL does not use the effective configured username'
assert_contains "$control_sql" 'CREATE OR REPLACE USER' \
    'MariaDB control-user SQL does not use the pre-10.6-compatible statement'
[[ "$control_sql" != *'ALTER USER'* ]] \
    || fail 'MariaDB control-user SQL prepares unsupported ALTER USER'
assert_contains "$control_sql" "ON \`phpmyadmin\`.*" \
    'control-user SQL does not grant access to the configured database'
assert_contains "$control_sql" 'GRANT ALL PRIVILEGES' \
    'control-user SQL does not restore the shipped phpMyAdmin privileges'
[[ "$control_sql" != *"control'secret"* ]] \
    || fail 'control-user password was inserted into SQL without encoding'

: >"$sql_log"
vx_pma_server_version() {
    /usr/bin/printf '8.0.39\n'
}
vx_pma_reconcile_control_user "$pma_config"
mysql_control_sql=$(<"$sql_log")
assert_contains "$mysql_control_sql" 'CREATE USER IF NOT EXISTS' \
    'MySQL control-user SQL does not create a missing account'
assert_contains "$mysql_control_sql" 'PREPARE vx_statement FROM @vx_create' \
    'MySQL control-user SQL prepares the wrong create statement'
assert_contains "$mysql_control_sql" 'ALTER USER' \
    'MySQL control-user SQL does not rotate an existing account password'

marker="$work_root/eval-ran"
/usr/bin/printf "%s\n" \
    "DB='alice_app' DBUSER='alice_app' TYPE='mysql' SUSPENDED='no'" \
    "DB='alice_pg' DBUSER='alice_pg' TYPE='pgsql' SUSPENDED='no'" \
    "DB='alice_literal' DBUSER='\$(touch $marker)' TYPE='mysql' SUSPENDED='yes'" \
    >"$VESTA/data/users/alice/db.conf"
/usr/bin/printf "%s\n" \
    "DB='bob_app' DBUSER='bob_app' TYPE='mysql' SUSPENDED='no'" \
    >"$VESTA/data/users/bob/db.conf"
managed_output=$(vx_pma_list_managed_databases)
assert_contains "$managed_output" 'alice_app' 'managed database list omitted alice database'
assert_contains "$managed_output" 'bob_app' 'managed database list omitted bob database'
[[ "$managed_output" != *'alice_pg'* ]] \
    || fail 'managed database list included a PostgreSQL database'
assert_contains "$managed_output" 'Total managed MySQL databases: 3' \
    'managed database total is incorrect'
[[ ! -e "$marker" ]] || fail 'managed database parsing evaluated configuration content'

vx_pma_mysql_execute() {
    [[ "$*" == --skip-column-names ]] \
        || fail 'server database listing omitted --skip-column-names'
    while IFS= read -r _line; do :; done
    /usr/bin/printf 'app\t1.25\nempty\t0.00\n'
}
server_output=$(vx_pma_list_server_databases)
assert_contains "$server_output" 'app' 'server database list omitted populated database'
assert_contains "$server_output" 'empty' 'server database list omitted empty database'

if [[ $EUID -ne 0 ]]; then
    /usr/bin/mkdir -p "$VESTA/conf"
    /usr/bin/ln -s "$repo_root/func" "$VESTA/func"
    /usr/bin/printf "DB_SYSTEM='mysql'\n" >"$VESTA/conf/vesta.conf"
    set +o errexit
    root_output=$("$repo_root/bin/v-add-vx-pma-admin" --list-only 2>&1)
    root_status=$?
    set -o errexit
    [[ $root_status -eq 10 ]] || fail 'public command did not use the Vesta forbidden exit code'
    assert_contains "$root_output" 'must be run as root' \
        'public command did not enforce root execution'
fi

if /usr/bin/grep -R -q 'vortex-scripts' \
    "$repo_root/bin/v-add-vx-pma-admin" "$repo_root/func/vx/pma-admin.sh"; then
    fail 'Vesta-owned implementation references vortex-scripts'
fi
/usr/bin/grep -Fqx 'VESTA=${VESTA:-/usr/local/vesta}' \
    "$repo_root/bin/v-add-vx-pma-admin" \
    || fail 'public command does not default VESTA for direct sudo execution'

printf 'pma admin tests passed\n'
