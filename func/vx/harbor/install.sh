#!/usr/bin/env bash

_vx_harbor_install_requirements() {
    local command available
    _vx_harbor_require_root || return 1
    for command in jq python3 sha256sum tar curl cosign docker systemctl nginx openssl; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
    available="$(/usr/bin/df -Pk "$(vx_harbor_root)" | /usr/bin/awk 'NR==2 {print $4}')" || return 1
    [[ "$available" =~ ^[0-9]+$ ]] && (( available >= ${VX_HARBOR_MIN_FREE_KB:-10485760} ))
}

_vx_harbor_install_compose_render() {
    local manifest="$1" destination="$2" name digest
    {
        printf 'name: vesta-harbor\nservices:\n'
        while IFS=$'\t' read -r name digest; do
            printf '  %s:\n    image: %s@%s\n    restart: unless-stopped\n    networks: [harbor]\n' "${name#goharbor/}" "$name" "$digest"
            if [[ "$name" == goharbor/nginx-photon ]]; then
                printf '    volumes:\n      - /run/vesta-harbor:/run/vesta-harbor\n'
            fi
        done < <(/usr/bin/jq -r '.images | to_entries[] | [.key,.value] | @tsv' "$manifest")
        printf 'networks:\n  harbor:\n    internal: true\n'
    } >"$destination"
    vx_harbor_release_images_validate "$manifest" "$destination"
}

_vx_harbor_install_restore_file() {
    local target="$1" backup="$2" existed="$3"
    if [[ "$existed" == yes ]]; then /usr/bin/cp -a -- "$backup" "$target"; else /usr/bin/rm -f -- "$target"; fi
}

vx_harbor_install() {
    local root stage manifest compose ingress unit_target ingress_target rollback
    local unit_existed=no ingress_existed=no current_existed=no candidate_activated=no service_active=no service_enabled=no committed=no
    root="$(vx_harbor_root)" || return 1
    vx_harbor_provider_prepare || return 1
    vx_harbor_provider_lock_acquire exclusive || return 1
    stage="$(/usr/bin/mktemp -d "$root/release/.install.XXXXXX")" || { vx_harbor_provider_lock_release; return 1; }
    rollback="$(/usr/bin/mktemp -d "$root/.install-rollback.XXXXXX")" || { vx_harbor_provider_lock_release; return 1; }
    unit_target="$(vx_harbor_systemd_target)"; ingress_target="$(vx_harbor_ingress_target)"
    [[ ! -L "$unit_target" && ! -L "$ingress_target" \
        && -d "$(dirname "$unit_target")" && ! -L "$(dirname "$unit_target")" \
        && -d "$(dirname "$ingress_target")" && ! -L "$(dirname "$ingress_target")" ]] \
        || { /usr/bin/rm -rf -- "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
    [[ -e "$unit_target" ]] && { /usr/bin/cp -a "$unit_target" "$rollback/unit"; unit_existed=yes; }
    [[ -e "$ingress_target" ]] && { /usr/bin/cp -a "$ingress_target" "$rollback/ingress"; ingress_existed=yes; }
    [[ -d "$root/release/current" ]] && current_existed=yes
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-active vesta-harbor.service >/dev/null 2>&1 && service_active=yes || :
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-enabled vesta-harbor.service >/dev/null 2>&1 && service_enabled=yes || :
    _vx_harbor_install_rollback() {
        [[ "$committed" == yes ]] && return 0
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service >/dev/null 2>&1 || :
        _vx_harbor_install_restore_file "$unit_target" "$rollback/unit" "$unit_existed" || :
        _vx_harbor_install_restore_file "$ingress_target" "$rollback/ingress" "$ingress_existed" || :
        if [[ "$candidate_activated" == yes ]]; then
            /usr/bin/rm -rf -- "$root/release/current"
            [[ "$current_existed" == yes && -d "$root/release/.prior-current" ]] && /usr/bin/mv "$root/release/.prior-current" "$root/release/current" || :
        fi
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" daemon-reload >/dev/null 2>&1 || :
        [[ "$service_enabled" == yes ]] && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" enable vesta-harbor.service >/dev/null 2>&1 || "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" disable vesta-harbor.service >/dev/null 2>&1 || :
        [[ "$service_active" == yes ]] && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service >/dev/null 2>&1 || :
        "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t >/dev/null 2>&1 && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service >/dev/null 2>&1 || :
    }
    trap '_vx_harbor_install_rollback; vx_harbor_provider_lock_release 2>/dev/null || :; exit 1' HUP INT TERM
    _vx_harbor_install_apply() {
        _vx_harbor_install_requirements || return 1
        vx_harbor_release_stage "$stage" || return 1
        manifest="$(vx_harbor_release_manifest)"; compose="$stage/compose.yaml"; ingress="$stage/harbor-registry.conf"
        _vx_harbor_install_compose_render "$manifest" "$compose" || return 1
        vx_harbor_ingress_render "$ingress" || return 1
        if [[ "$current_existed" == yes ]]; then /usr/bin/mv "$root/release/current" "$root/release/.prior-current" || return 1; fi
        /usr/bin/mv "$stage" "$root/release/current" || return 1
        candidate_activated=yes
        stage="$root/release/current"
        ingress="$stage/harbor-registry.conf"
        /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$VESTA/install/harbor/vesta-harbor.service" "$unit_target" || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" daemon-reload || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" enable vesta-harbor.service || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service || return 1
        "${VX_HARBOR_MIGRATION_CHECK:-/bin/true}" || return 1
        "${VX_HARBOR_HEALTH_CHECK:-/bin/true}" || return 1
        vx_harbor_socket_validate || return 1
        vx_harbor_ingress_activate "$ingress" || return 1
    }
    if ! _vx_harbor_install_apply; then
        _vx_harbor_install_rollback
        trap - HUP INT TERM
        /usr/bin/rm -rf -- "$rollback"
        vx_harbor_provider_lock_release
        return 1
    fi
    /usr/bin/rm -rf -- "$root/release/previous"
    [[ -d "$root/release/.prior-current" ]] && /usr/bin/mv "$root/release/.prior-current" "$root/release/previous"
    /usr/bin/jq --arg origin "$(vx_harbor_origin_json | /usr/bin/jq -r '.ORIGIN')" \
      --arg hash "$(/usr/bin/sha256sum "$manifest" | /usr/bin/awk '{print $1}')" \
      '.MODE="managed" | .RUNNING_VERSION="v2.15.0" | .PINNED_VERSION="v2.15.0" | .ORIGIN=$origin | .RELEASE_MANIFEST_SHA256=$hash | .INSTALLATION_ID=(.INSTALLATION_ID // "vesta-harbor")' \
      "$root/provider.json" >"$root/.provider-install.json" || return 1
    vx_harbor_json_write_atomic "$root/provider.json" "$root/.provider-install.json" || return 1
    /usr/bin/rm -f "$root/.provider-install.json"
    committed=yes
    trap - HUP INT TERM
    /usr/bin/rm -rf -- "$rollback"
    vx_harbor_provider_lock_release
}
