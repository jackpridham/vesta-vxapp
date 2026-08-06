#!/usr/bin/env bash

_vx_compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${_VX_COMPOSE_MAIN_LOADED:-}"
    || "$(declare -p _VX_COMPOSE_MAIN_LOADED 2>/dev/null)" == declare\ -x* ]]; then
    _vx_inherited_lock_fd="${VX_COMPOSE_LOCK_FD:-}"
    _vx_inherited_lock_key="${VX_COMPOSE_LOCK_KEY:-}"
    _vx_inherited_lock_depth="${VX_COMPOSE_LOCK_DEPTH:-}"
    unset _VX_COMPOSE_MAIN_LOADED
    if [[ "$_vx_inherited_lock_fd" =~ ^[0-9]+$
        && "$_vx_inherited_lock_fd" -gt 2
        && "$_vx_inherited_lock_key" \
            =~ ^([a-z0-9][a-z0-9_-]{0,31})/([a-z0-9][a-z0-9-]{0,62})$
        && "$_vx_inherited_lock_depth" =~ ^[1-9][0-9]*$ ]]; then
        _vx_inherited_lock_owner="${_vx_inherited_lock_key%%/*}"
        _vx_inherited_lock_project="${_vx_inherited_lock_key#*/}"
        _vx_inherited_lock_expected="$VESTA/data/users/$_vx_inherited_lock_owner/docker-projects/.locks/$_vx_inherited_lock_project.lock"
        _vx_inherited_lock_target="$(
            readlink "/proc/$$/fd/$_vx_inherited_lock_fd" 2>/dev/null
        )"
        if [[ -f "$_vx_inherited_lock_expected"
            && ! -L "$_vx_inherited_lock_expected"
            && "$_vx_inherited_lock_target" \
                == "$(readlink -f -- "$_vx_inherited_lock_expected")" ]]; then
            eval "exec ${_vx_inherited_lock_fd}>&-"
        fi
    fi
    unset VX_COMPOSE_LOCK_FD VX_COMPOSE_LOCK_KEY VX_COMPOSE_LOCK_DEPTH
    unset _vx_inherited_lock_fd _vx_inherited_lock_key \
        _vx_inherited_lock_depth _vx_inherited_lock_owner \
        _vx_inherited_lock_project _vx_inherited_lock_expected \
        _vx_inherited_lock_target
    _VX_COMPOSE_MAIN_LOADED=1
fi

# shellcheck source=func/vx/compose/common.sh
source "$_vx_compose_dir/common.sh"
# shellcheck source=func/vx/compose/profile.sh
source "$_vx_compose_dir/profile.sh"
# shellcheck source=func/vx/compose/policy.sh
source "$_vx_compose_dir/policy.sh"
# shellcheck source=func/vx/compose/storage.sh
source "$_vx_compose_dir/storage.sh"
# shellcheck source=func/vx/compose/audit.sh
source "$_vx_compose_dir/audit.sh"
# shellcheck source=func/vx/compose/operations.sh
source "$_vx_compose_dir/operations.sh"
# shellcheck source=func/vx/compose/paths.sh
source "$_vx_compose_dir/paths.sh"
# shellcheck source=func/vx/compose/network.sh
source "$_vx_compose_dir/network.sh"
# shellcheck source=func/vx/compose/ports.sh
source "$_vx_compose_dir/ports.sh"
# shellcheck source=func/vx/compose/volumes.sh
source "$_vx_compose_dir/volumes.sh"
# shellcheck source=func/vx/compose/canonicalize.sh
source "$_vx_compose_dir/canonicalize.sh"
# shellcheck source=func/vx/compose/quota.sh
source "$_vx_compose_dir/quota.sh"
# shellcheck source=func/vx/compose/registry.sh
source "$_vx_compose_dir/registry.sh"
# shellcheck source=func/vx/compose/images.sh
source "$_vx_compose_dir/images.sh"
# shellcheck source=func/vx/compose/image-approvals.sh
source "$_vx_compose_dir/image-approvals.sh"
# shellcheck source=func/vx/compose/trust.sh
source "$_vx_compose_dir/trust.sh"
# shellcheck source=func/vx/compose/secrets.sh
source "$_vx_compose_dir/secrets.sh"
# shellcheck source=func/vx/compose/bundles.sh
source "$_vx_compose_dir/bundles.sh"
# shellcheck source=func/vx/compose/probes.sh
source "$_vx_compose_dir/probes.sh"
# shellcheck source=func/vx/compose/restore.sh
source "$_vx_compose_dir/restore.sh"
# shellcheck source=func/vx/compose/backup.sh
source "$_vx_compose_dir/backup.sh"
# shellcheck source=func/vx/compose/backup-policy.sh
source "$_vx_compose_dir/backup-policy.sh"
# shellcheck source=func/vx/compose/routes.sh
source "$_vx_compose_dir/routes.sh"
# shellcheck source=func/vx/compose/ingress.sh
source "$_vx_compose_dir/ingress.sh"
# shellcheck source=func/vx/compose/health.sh
source "$_vx_compose_dir/health.sh"
# shellcheck source=func/vx/compose/logs.sh
source "$_vx_compose_dir/logs.sh"
# shellcheck source=func/vx/compose/metrics.sh
source "$_vx_compose_dir/metrics.sh"
# shellcheck source=func/vx/compose/alerts.sh
source "$_vx_compose_dir/alerts.sh"
# shellcheck source=func/vx/compose/roles.sh
source "$_vx_compose_dir/roles.sh"
# shellcheck source=func/vx/compose/drift.sh
source "$_vx_compose_dir/drift.sh"
# shellcheck source=func/vx/compose/revisions.sh
source "$_vx_compose_dir/revisions.sh"
unset _VX_COMPOSE_AUDIT_ACTOR
unset VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE
# shellcheck source=func/vx/compose/deployment.sh
source "$_vx_compose_dir/deployment.sh"
# shellcheck source=func/vx/compose/transaction.sh
source "$_vx_compose_dir/transaction.sh"
# shellcheck source=func/vx/compose/adopt.sh
source "$_vx_compose_dir/adopt.sh"
# shellcheck source=func/vx/compose/migrate.sh
source "$_vx_compose_dir/migrate.sh"
# shellcheck source=func/vx/compose/simple.sh
source "$_vx_compose_dir/simple.sh"
# shellcheck source=func/vx/compose/web.sh
source "$_vx_compose_dir/web.sh"
# shellcheck source=func/vx/compose/package.sh
source "$_vx_compose_dir/package.sh"
# shellcheck source=func/vx/compose/lifecycle.sh
source "$_vx_compose_dir/lifecycle.sh"
# shellcheck source=func/vx/compose/owner.sh
source "$_vx_compose_dir/owner.sh"

unset _vx_compose_dir
