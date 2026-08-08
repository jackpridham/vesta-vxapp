#!/usr/bin/env bash

case "${0##*/}" in
    v-*)
        for _vx_harbor_public_variable in "${!VX_HARBOR_@}"; do
            unset "$_vx_harbor_public_variable"
        done
        unset _vx_harbor_public_variable
        ;;
esac

_vx_harbor_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=func/vx/harbor/common.sh
source "$_vx_harbor_dir/common.sh"
# shellcheck source=func/vx/harbor/audit.sh
source "$_vx_harbor_dir/audit.sh"
# shellcheck source=func/vx/harbor/package.sh
source "$_vx_harbor_dir/package.sh"

unset _vx_harbor_dir
