#!/bin/bash
# Vortex native web proxy helpers. Keep redirect/proxy behavior isolated from
# upstream MyVesta scripts so rebases only need thin hook reapplication.

VX_PROXY_TEMPLATE="vx-proxy"
VX_PROXY_DEFAULT_MODE="proxy"
VX_PROXY_DEFAULT_PROFILE="standard"
VX_PROXY_DEFAULT_TIMEOUT="60"
VX_PROXY_DEFAULT_PRESERVE_HOST="yes"
VX_PROXY_HEADER_SEPARATOR="||"

vx_proxy_reset_options() {
    VX_PROXY_OPTION_MODE=""
    VX_PROXY_OPTION_TARGET=""
    VX_PROXY_OPTION_PROFILE=""
    VX_PROXY_OPTION_PRESERVE_HOST=""
    VX_PROXY_OPTION_TIMEOUT=""
    VX_PROXY_OPTION_HEADERS=""
}

vx_proxy_append_header_option() {
    if [ -z "$VX_PROXY_OPTION_HEADERS" ]; then
        VX_PROXY_OPTION_HEADERS="$1"
    else
        VX_PROXY_OPTION_HEADERS="${VX_PROXY_OPTION_HEADERS}${VX_PROXY_HEADER_SEPARATOR}$1"
    fi
}

vx_proxy_parse_long_options() {
    vx_proxy_reset_options

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --proxy-target)
                [ -n "$2" ] || check_result "$E_ARGS" "--proxy-target requires a URL"
                VX_PROXY_OPTION_TARGET="$2"
                shift 2
                ;;
            --proxy-mode)
                [ -n "$2" ] || check_result "$E_ARGS" "--proxy-mode requires a value"
                VX_PROXY_OPTION_MODE="$2"
                shift 2
                ;;
            --proxy-profile)
                [ -n "$2" ] || check_result "$E_ARGS" "--proxy-profile requires a value"
                VX_PROXY_OPTION_PROFILE="$2"
                shift 2
                ;;
            --proxy-preserve-host)
                [ -n "$2" ] || check_result "$E_ARGS" "--proxy-preserve-host requires yes or no"
                VX_PROXY_OPTION_PRESERVE_HOST="$2"
                shift 2
                ;;
            --proxy-timeout)
                [ -n "$2" ] || check_result "$E_ARGS" "--proxy-timeout requires seconds"
                VX_PROXY_OPTION_TIMEOUT="$2"
                shift 2
                ;;
            --header|--proxy-header)
                [ -n "$2" ] || check_result "$E_ARGS" "--header requires 'Name: Value'"
                vx_proxy_append_header_option "$2"
                shift 2
                ;;
            "")
                shift
                ;;
            *)
                check_result "$E_ARGS" "unknown proxy option $1"
                ;;
        esac
    done
}

vx_proxy_apply_option_globals() {
    [ -n "$VX_PROXY_OPTION_MODE" ] && PROXY_MODE="$VX_PROXY_OPTION_MODE"
    [ -n "$VX_PROXY_OPTION_TARGET" ] && PROXY_TARGET="$VX_PROXY_OPTION_TARGET"
    [ -n "$VX_PROXY_OPTION_PROFILE" ] && PROXY_PROFILE="$VX_PROXY_OPTION_PROFILE"
    [ -n "$VX_PROXY_OPTION_PRESERVE_HOST" ] && PROXY_PRESERVE_HOST="$VX_PROXY_OPTION_PRESERVE_HOST"
    [ -n "$VX_PROXY_OPTION_TIMEOUT" ] && PROXY_TIMEOUT="$VX_PROXY_OPTION_TIMEOUT"
    [ -n "$VX_PROXY_OPTION_HEADERS" ] && PROXY_HEADERS="$VX_PROXY_OPTION_HEADERS"
}

vx_proxy_apply_positional_globals() {
    PROXY_MODE="$1"
    PROXY_TARGET="$2"
    PROXY_PROFILE="$3"
    PROXY_PRESERVE_HOST="$4"
    PROXY_TIMEOUT="$5"
    PROXY_HEADERS="$6"
}

vx_proxy_defaults() {
    [ -n "$PROXY_MODE" ] || PROXY_MODE="$VX_PROXY_DEFAULT_MODE"
    [ -n "$PROXY_PROFILE" ] || PROXY_PROFILE="$VX_PROXY_DEFAULT_PROFILE"
    [ -n "$PROXY_PRESERVE_HOST" ] || PROXY_PRESERVE_HOST="$VX_PROXY_DEFAULT_PRESERVE_HOST"
    [ -n "$PROXY_TIMEOUT" ] || PROXY_TIMEOUT="$VX_PROXY_DEFAULT_TIMEOUT"
    [ -n "$PROXY_HEADERS" ] || PROXY_HEADERS=""
}

vx_proxy_validate_mode() {
    case "$PROXY_MODE" in
        proxy|redirect|redirect-temp) return 0 ;;
    esac
    check_result "$E_INVALID" "proxy mode is invalid"
}

vx_proxy_validate_profile() {
    case "$PROXY_PROFILE" in
        standard|websocket|application|streaming|media) return 0 ;;
    esac
    check_result "$E_INVALID" "proxy profile is invalid"
}

vx_proxy_validate_bool() {
    case "$PROXY_PRESERVE_HOST" in
        yes|no) return 0 ;;
    esac
    check_result "$E_INVALID" "proxy preserve host value is invalid"
}

vx_proxy_validate_timeout() {
    if ! [[ "$PROXY_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$PROXY_TIMEOUT" -lt 1 ] || [ "$PROXY_TIMEOUT" -gt 3600 ]; then
        check_result "$E_INVALID" "proxy timeout is invalid"
    fi
}

vx_proxy_validate_target() {
    if [ -z "$PROXY_TARGET" ]; then
        check_result "$E_INVALID" "proxy target is required"
    fi
    if ! [[ "$PROXY_TARGET" =~ ^https?://[^[:space:]\'\"\;\{\}\#\|]+$ ]]; then
        check_result "$E_INVALID" "proxy target URL is invalid"
    fi
}

vx_proxy_validate_headers() {
    local header name value

    [ -n "$PROXY_HEADERS" ] || return 0
    while IFS= read -r header; do
        [ -n "$header" ] || continue
        name="${header%%:*}"
        value="${header#*:}"
        value="${value# }"
        if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || [ -z "$value" ]; then
            check_result "$E_INVALID" "proxy header format is invalid"
        fi
        if [[ "$value" =~ [\'\"\;\{\}\\\|] ]] || [[ "$value" == *$'\n'* ]]; then
            check_result "$E_INVALID" "proxy header value is invalid"
        fi
    done <<< "${PROXY_HEADERS//$VX_PROXY_HEADER_SEPARATOR/$'\n'}"
}

vx_proxy_validate() {
    vx_proxy_defaults
    vx_proxy_validate_target
    vx_proxy_validate_mode
    vx_proxy_validate_profile
    vx_proxy_validate_bool
    vx_proxy_validate_timeout
    vx_proxy_validate_headers
}

vx_proxy_target_host() {
    echo "$PROXY_TARGET" | sed -E 's|^https?://([^/:]+).*$|\1|'
}

vx_proxy_is_native() {
    [ "$PROXY" = "$VX_PROXY_TEMPLATE" ] || [ -n "$PROXY_TARGET" ]
}

vx_proxy_ensure_web_conf_keys() {
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_MODE' 'STATS'
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_TARGET' 'STATS'
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_PRESERVE_HOST' 'STATS'
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_PROFILE' 'STATS'
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_TIMEOUT' 'STATS'
    add_object_key 'web' 'DOMAIN' "$domain" 'PROXY_HEADERS' 'STATS'
}

vx_proxy_update_web_conf() {
    vx_proxy_ensure_web_conf_keys
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_MODE' "$PROXY_MODE"
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_TARGET' "$PROXY_TARGET"
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_PRESERVE_HOST' "$PROXY_PRESERVE_HOST"
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_PROFILE' "$PROXY_PROFILE"
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_TIMEOUT' "$PROXY_TIMEOUT"
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_HEADERS' "$PROXY_HEADERS"
}

vx_proxy_clear_web_conf() {
    vx_proxy_ensure_web_conf_keys
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_MODE' ""
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_TARGET' ""
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_PRESERVE_HOST' ""
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_PROFILE' ""
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_TIMEOUT' ""
    update_object_value 'web' 'DOMAIN' "$domain" '$PROXY_HEADERS' ""
}

vx_proxy_build_header_block() {
    local header name value

    [ -n "$PROXY_HEADERS" ] || return 0
    while IFS= read -r header; do
        [ -n "$header" ] || continue
        name="${header%%:*}"
        value="${header#*:}"
        value="${value# }"
        printf '        proxy_set_header %s "%s";\n' "$name" "$value"
    done <<< "${PROXY_HEADERS//$VX_PROXY_HEADER_SEPARATOR/$'\n'}"
}

vx_proxy_build_profile_block() {
    local timeout="$PROXY_TIMEOUT"
    if [ "$PROXY_PROFILE" = "streaming" ] || [ "$PROXY_PROFILE" = "media" ]; then
        timeout="3600"
    fi

    cat <<EOF
        proxy_http_version 1.1;
        proxy_connect_timeout ${timeout}s;
        proxy_send_timeout ${timeout}s;
        proxy_read_timeout ${timeout}s;
        send_timeout ${timeout}s;
EOF

    if [ "$PROXY_PROFILE" = "websocket" ] || [ "$PROXY_PROFILE" = "application" ] || \
       [ "$PROXY_PROFILE" = "streaming" ] || [ "$PROXY_PROFILE" = "media" ]; then
        cat <<'EOF'
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
EOF
    else
        cat <<'EOF'
        proxy_set_header Connection "";
EOF
    fi

    if [ "$PROXY_PROFILE" = "streaming" ] || [ "$PROXY_PROFILE" = "media" ]; then
        cat <<'EOF'
        proxy_request_buffering off;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
EOF
    fi

    if [ "$PROXY_PROFILE" = "media" ]; then
        cat <<'EOF'
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src https: data: blob: ; img-src 'self' https://* ; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' https://www.gstatic.com https://www.youtube.com https://*.googleapis.com https://*.gstatic.com blob:; worker-src 'self' blob:; connect-src 'self' https://*.googleapis.com https://*.gstatic.com wss:; object-src 'none'; frame-ancestors 'self'; font-src 'self' https://fonts.gstatic.com; media-src 'self' blob: data:;" always;
EOF
    fi
}

vx_proxy_prepare_template_values() {
    VX_PROXY_LOCATION_BLOCK=""
    [ "$PROXY" = "$VX_PROXY_TEMPLATE" ] || [ "$PROXY_TEMPLATE" = "$VX_PROXY_TEMPLATE" ] || return 0

    vx_proxy_defaults
    vx_proxy_validate

    if [ "$PROXY_MODE" = "redirect" ] || [ "$PROXY_MODE" = "redirect-temp" ]; then
        local redirect_code="301"
        [ "$PROXY_MODE" = "redirect-temp" ] && redirect_code="302"
        VX_PROXY_LOCATION_BLOCK="    location / {
        return ${redirect_code} ${PROXY_TARGET}\$request_uri;
    }"
        return 0
    fi

    local target_host
    target_host=$(vx_proxy_target_host)
    local host_header='        proxy_set_header Host $host;'
    [ "$PROXY_PRESERVE_HOST" = "no" ] && host_header="        proxy_set_header Host ${target_host};"

    local ssl_block=""
    if [[ "$PROXY_TARGET" =~ ^https:// ]]; then
        ssl_block="        proxy_ssl_verify off;
        proxy_ssl_server_name on;"
    fi

    VX_PROXY_LOCATION_BLOCK="    location / {
        proxy_pass ${PROXY_TARGET};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
${host_header}
${ssl_block}
$(vx_proxy_build_profile_block)
        proxy_redirect off;
        proxy_buffering off;
$(vx_proxy_build_header_block)
    }"
}

vx_proxy_apply_template_blocks() {
    local line
    while IFS= read -r line; do
        case "$line" in
            *%vx_proxy_location_block%*)
                printf '%s\n' "$VX_PROXY_LOCATION_BLOCK"
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done
}
