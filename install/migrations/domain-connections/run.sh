#!/bin/bash
# info: explicitly assess, prepare, apply, rollback or finalize native domain adoption
# options: ACTION USER NATIVE_PRIMARY [REVISION]
set -u -o pipefail
umask 077
VESTA=${VESTA:-/usr/local/vesta}
action=${1:-}; user=${2:-}; hostname=${3:-}; revision=${4:-}
[[ $# -ge 3 && $# -le 4 && "$user" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || exit 2
case "$action" in assess|prepare|status) [[ $# == 3 ]] || exit 2;; apply|rollback|finalize) [[ "$revision" =~ ^[a-f0-9]{64}$ ]] || exit 2;; *) exit 2;; esac
source "$VESTA/func/main.sh"
source "$VESTA/conf/vesta.conf"
source "$VESTA/func/vx/domain-connections/main.sh"
source "$VESTA/func/vx/domain-connections/migration.sh"
"vx_domain_connection_migration_$action" "$user" "$hostname" "$revision"
