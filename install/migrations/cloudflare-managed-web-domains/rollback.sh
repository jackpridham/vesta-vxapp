#!/bin/bash

set -u -o pipefail
umask 077

VESTA=${VESTA:-/usr/local/vesta}
source "$VESTA/func/vx/cloudflare/main.sh"
source "$VESTA/func/vx/cloudflare/migration.sh"
source "$VESTA/conf/vesta.conf"

plan=${1:-}
format=human
valid=yes
shift "$(( $# > 0 ? 1 : 0 ))"
if (( $# == 1 )) && [[ "$1" == --json ]]; then
    format=json
    shift
fi
(( $# == 0 )) || valid=no
if [[ "$valid" != yes ]]; then
    vx_cf_migration_emit "$format" invalid_argument 0 0 0 0 1
    exit 2
fi
vx_cf_migration_rollback "$plan" "$format"
