#!/bin/bash

set -u -o pipefail
umask 077

VESTA=${VESTA:-/usr/local/vesta}
source "$VESTA/func/vx/cloudflare/main.sh"
source "$VESTA/func/vx/cloudflare/migration.sh"
source "$VESTA/conf/vesta.conf"

plan=${1:-}
scope=all
format=human
valid=yes
shift "$(( $# > 0 ? 1 : 0 ))"
while (( $# > 0 )); do
    case "$1" in
        --user)
            [[ "$scope" == all && $# -ge 2 ]] || { valid=no; break; }
            scope=$2
            shift 2
            ;;
        --json)
            [[ "$format" == human ]] || { valid=no; break; }
            format=json
            shift
            ;;
        *)
            valid=no
            break
            ;;
    esac
done
if [[ "$valid" != yes ]]; then
    vx_cf_migration_emit "$format" invalid_argument 0 0 0 0 1
    exit 2
fi
vx_cf_migration_prepare "$plan" "$scope" "$format"
