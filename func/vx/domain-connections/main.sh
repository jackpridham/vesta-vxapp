#!/usr/bin/env bash

# Root-owned connection state.  Native-domain operations deliberately live in
# native.sh so that this registry remains the cross-tenant ownership authority.
_vx_domain_connections_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$_vx_domain_connections_dir/../graceful-apply.sh"
# shellcheck source=func/vx/domain-connections/state.sh
source "$_vx_domain_connections_dir/state.sh"
# shellcheck source=func/vx/domain-connections/dns.sh
source "$_vx_domain_connections_dir/dns.sh"
source "$_vx_domain_connections_dir/target.sh"
source "$_vx_domain_connections_dir/native.sh"
# shellcheck source=func/vx/domain-connections/worker.sh
source "$_vx_domain_connections_dir/worker.sh"
unset _vx_domain_connections_dir
