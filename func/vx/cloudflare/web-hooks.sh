#!/bin/bash

# Thin native web-domain hooks for VX-owned Origin CA rotation. Callers have
# already loaded func/domain.sh, func/ip.sh, the Cloudflare helper, and the
# current web-domain values.

vx_cf_rebuild_alias_configs() {
    del_web_config "$WEB_SYSTEM" "$TPL.tpl"
    add_web_config "$WEB_SYSTEM" "$TPL.tpl"
    if [[ "$SSL" == yes ]]; then
        del_web_config "$WEB_SYSTEM" "$TPL.stpl"
        add_web_config "$WEB_SYSTEM" "$TPL.stpl"
    fi
    if [[ -n "$PROXY_SYSTEM" && -n "$PROXY" ]]; then
        del_web_config "$PROXY_SYSTEM" "$PROXY.tpl"
        add_web_config "$PROXY_SYSTEM" "$PROXY.tpl"
        if [[ "$SSL" == yes ]]; then
            del_web_config "$PROXY_SYSTEM" "$PROXY.stpl"
            add_web_config "$PROXY_SYSTEM" "$PROXY.stpl"
        fi
    fi
}

vx_cf_reconcile_alias_change() {
    local previous_alias=$1 direction=$2 restart=${3:-yes} failure

    vx_cf_metadata_exists "$user" "$domain" || return 0
    if VESTA="$VESTA" "$BIN/v-reconcile-vx-cloudflare-origin-ssl" \
        "$user" "$domain" no >/dev/null 2>&1; then
        return 0
    fi
    failure=certificate_error

    # Restore persisted and rendered alias authority before returning failure.
    ALIAS=$previous_alias
    prepare_web_domain_values
    vx_cf_rebuild_alias_configs
    update_object_value web DOMAIN "$domain" '$ALIAS' "$ALIAS"
    if [[ "$direction" == add ]]; then
        decrease_user_value "$user" '$U_WEB_ALIASES'
    else
        increase_user_value "$user" '$U_WEB_ALIASES'
    fi
    "$BIN/v-restart-web" "$restart" >/dev/null 2>&1 || :
    "$BIN/v-restart-proxy" "$restart" >/dev/null 2>&1 || :
    VX_CF_STATUS=$failure
    return 1
}
