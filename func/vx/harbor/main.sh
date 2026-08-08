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
# shellcheck source=func/vx/harbor/status.sh
source "$_vx_harbor_dir/status.sh"
# shellcheck source=func/vx/harbor/api.sh
source "$_vx_harbor_dir/api.sh"
# shellcheck source=func/vx/harbor/quota.sh
source "$_vx_harbor_dir/quota.sh"
# shellcheck source=func/vx/harbor/credentials.sh
source "$_vx_harbor_dir/credentials.sh"
# shellcheck source=func/vx/harbor/publisher.sh
source "$_vx_harbor_dir/publisher.sh"
# shellcheck source=func/vx/harbor/owners.sh
source "$_vx_harbor_dir/owners.sh"
# shellcheck source=func/vx/harbor/package.sh
source "$_vx_harbor_dir/package.sh"
# shellcheck source=func/vx/harbor/release.sh
source "$_vx_harbor_dir/release.sh"
# shellcheck source=func/vx/harbor/ingress.sh
source "$_vx_harbor_dir/ingress.sh"
# shellcheck source=func/vx/harbor/install.sh
source "$_vx_harbor_dir/install.sh"

unset _vx_harbor_dir
