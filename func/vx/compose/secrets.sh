#!/usr/bin/env bash

vx_compose_secret_name_is_valid() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,62}$ ]]
}

vx_compose_secret_path() {
    printf '%s/secrets/%s\n' "$(vx_compose_project_root "$1" "$2")" "$3"
}

vx_compose_secret_metadata_path() {
    printf '%s/secrets.json\n' "$(vx_compose_project_root "$1" "$2")"
}

vx_compose_secret_count() {
    local owner="$1"
    local projects_root project_root secret_file count=0

    projects_root="$(vx_compose_projects_root "$owner")"
    [[ -d "$projects_root" ]] || {
        printf '%s\n' 0
        return
    }
    for project_root in "$projects_root"/*; do
        [[ -d "$project_root/secrets" ]] || continue
        for secret_file in "$project_root/secrets"/*; do
            [[ -f "$secret_file" && ! -L "$secret_file" ]] || continue
            count=$((count + 1))
        done
    done
    printf '%s\n' "$count"
}

vx_compose_secret_input_validate() {
    local value_file="$1"

    [[ -f "$value_file" && ! -L "$value_file" ]] \
        || {
            vx_compose_error 'secret input must be a regular non-symlink file'
            return 1
        }
    [[ "$(stat -c '%s' "$value_file")" -gt 0
        && "$(stat -c '%s' "$value_file")" -le 1048576 ]] \
        || {
            vx_compose_error 'secret input size is invalid'
            return 1
        }
    [[ "$(stat -c '%a' "$value_file")" == 600 ]] \
        || {
            vx_compose_error 'secret input must have mode 0600'
            return 1
        }
}

vx_compose_secret_metadata_update() {
    local owner="$1"
    local project="$2"
    local name="$3"
    local sha="$4"
    local metadata root temp_file now created

    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$(vx_compose_secret_metadata_path "$owner" "$project")"
    [[ -f "$metadata" ]] || printf '%s\n' '{}' >"$metadata"
    now="$(vx_compose_now)"
    created="$(jq -r --arg name "$name" '.[$name].CREATED // empty' "$metadata")"
    [[ -n "$created" ]] || created="$now"
    temp_file="$(mktemp "$root/.secrets.XXXXXX")"
    jq -S \
        --arg name "$name" \
        --arg sha "$sha" \
        --arg created "$created" \
        --arg rotated "$now" \
        '.[$name] = {
            NAME: $name,
            TARGET: ("/run/secrets/" + $name),
            SHA256: $sha,
            CREATED: $created,
            ROTATED: $rotated
        }' "$metadata" >"$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$metadata"
}

vx_compose_secret_install() {
    local owner="$1"
    local project="$2"
    local name="$3"
    local value_file="$4"
    local action="$5"
    local root secrets_root secret_file temp_file sha metadata
    local current_size=0 new_size growth_mb measured_storage
    local rollback_secret rollback_metadata redaction_root service
    local result=0 recovery_result=0 had_metadata=no had_secret=no
    local swapped=no
    local affected_services='[]'

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_secret_name_is_valid "$name" \
        || {
            vx_compose_error 'invalid Compose secret name'
            return 1
        }
    vx_compose_secret_input_validate "$value_file" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    secrets_root="$root/secrets"
    secret_file="$(vx_compose_secret_path "$owner" "$project" "$name")"
    install -d -m 0700 "$secrets_root"
    if [[ "$action" == add && -e "$secret_file" ]]; then
        vx_compose_error "Compose secret already exists: $name"
        return 1
    fi
    if [[ "$action" == change && ! -f "$secret_file" ]]; then
        vx_compose_error "Compose secret does not exist: $name"
        return 1
    fi
    vx_compose_lock_acquire "$owner" "$project" || return 1
    vx_compose_ports_lock_acquire || {
        vx_compose_lock_release
        return 1
    }
    vx_compose_owner_quota_lock_acquire "$owner" || {
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    if [[ "$action" == add && -e "$secret_file" ]]; then
        vx_compose_error "Compose secret already exists: $name"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "$action" == change && ! -f "$secret_file" ]]; then
        vx_compose_error "Compose secret does not exist: $name"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "$action" == add ]]; then
        vx_compose_quota_compare \
            "$owner" DOCKER_SECRETS "$(( $(vx_compose_secret_count "$owner") + 1 ))" \
            || {
                vx_compose_owner_quota_lock_release
                vx_compose_ports_lock_release
                vx_compose_lock_release
                return 1
            }
    fi
    [[ -f "$secret_file" ]] && current_size="$(stat -c '%s' "$secret_file")"
    new_size="$(stat -c '%s' "$value_file")"
    growth_mb=0
    if (( new_size > current_size )); then
        growth_mb=$(( (new_size - current_size + 1048575) / 1048576 ))
    fi
    measured_storage="$(vx_compose_measured_storage_mb "$owner")" || {
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    vx_compose_quota_compare \
        "$owner" DOCKER_STORAGE_MB "$((measured_storage + growth_mb))" \
        || {
            vx_compose_owner_quota_lock_release
            vx_compose_ports_lock_release
            vx_compose_lock_release
            return 1
        }
    temp_file="$(mktemp "$secrets_root/.${name}.XXXXXX")" || {
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    if ! install -m 0600 "$value_file" "$temp_file"; then
        rm -f -- "$temp_file"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    sha="$(sha256sum "$temp_file" | awk '{print $1}')"
    metadata="$(vx_compose_secret_metadata_path "$owner" "$project")"
    rollback_secret="$secrets_root/.${name}.rollback.$$"
    rollback_metadata="$root/.secrets.rollback.$$"
    redaction_root="$root/runtime/secret-redaction"
    [[ ! -e "$rollback_secret" && ! -e "$rollback_metadata" ]] || result=1
    if [[ "$result" -eq 0 ]]; then
        if ! install -d -m 0700 "$redaction_root" \
            || ! install -m 0600 "$value_file" "$redaction_root/new"; then
            result=1
        fi
    fi
    if [[ "$result" -eq 0 ]]; then
        if [[ -f "$secret_file" ]]; then
            had_secret=yes
            if [[ "${VX_COMPOSE_TEST_SECRET_COPY_FAIL:-}" == old ]] \
                || ! install -m 0600 "$secret_file" "$rollback_secret" \
                || ! install -m 0600 "$secret_file" "$redaction_root/old"; then
                result=1
            fi
        fi
        if [[ "$result" -eq 0 && -f "$metadata" ]]; then
            had_metadata=yes
            if [[ "${VX_COMPOSE_TEST_SECRET_COPY_FAIL:-}" == metadata ]] \
                || ! install -m 0600 "$metadata" "$rollback_metadata"; then
                result=1
            fi
        fi
    fi
    if [[ "$action" == change && "$result" -eq 0 ]]; then
        affected_services="$(jq -c --arg name "$name" '
            [
                .services
                | to_entries[]
                | select(any((.value.secrets // [])[];
                    (.source // .) == $name
                ))
                | .key
            ]
        ' "$root/runtime/canonical.json")" || result=1
    fi
    if [[ "$result" -eq 0 ]] && ! mv -f -- "$temp_file" "$secret_file"; then
        result=1
    elif [[ "$result" -eq 0 ]]; then
        swapped=yes
    fi
    [[ "$result" -ne 0 ]] || chmod 0600 "$secret_file" || result=1
    if [[ "$result" -eq 0 ]] \
        && ! vx_compose_secret_metadata_update \
            "$owner" "$project" "$name" "$sha"; then
        result=1
    fi
    if [[ "$result" -eq 0 && "$action" == change ]]; then
        while IFS= read -r service; do
            vx_compose_recreate "$owner" "$project" "$service" || {
                result=1
                break
            }
        done < <(jq -r '.[]' <<<"$affected_services")
    fi
    if [[ "$result" -eq 0 ]]; then
        if ! vx_compose_audit "$root" "secret-$action" succeeded; then
            result=1
        elif ! rm -rf -- "$redaction_root"; then
            result=1
        elif ! rm -f -- "$rollback_secret" "$rollback_metadata"; then
            result=1
        fi
    fi
    if [[ "$result" -ne 0 ]]; then
        rm -f -- "$temp_file"
        if [[ "$swapped" == yes ]]; then
            if [[ "$had_secret" == yes ]]; then
                install -m 0600 "$rollback_secret" "$secret_file" \
                    || recovery_result=1
            else
                rm -f -- "$secret_file"
            fi
            if [[ "$had_metadata" == yes ]]; then
                install -m 0600 "$rollback_metadata" "$metadata" \
                    || recovery_result=1
            else
                rm -f -- "$metadata"
            fi
        fi
        if [[ "$action" == change && "$swapped" == yes ]]; then
            while IFS= read -r service; do
                vx_compose_recreate "$owner" "$project" "$service" \
                    || recovery_result=1
            done < <(jq -r '.[]' <<<"$affected_services")
        fi
        if [[ "$recovery_result" -ne 0 ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
        fi
        vx_compose_audit "$root" "secret-$action" failed \
            'secret rotation failed; prior value restored' || :
        if ! rm -f -- "$rollback_secret" "$rollback_metadata" \
            || ! rm -rf -- "$redaction_root"; then
            recovery_result=1
            vx_compose_update_state \
                "$owner" "$project" restore-required || :
        fi
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    rm -f -- "$value_file"
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
    vx_compose_lock_release
    vx_compose_refresh_counters "$owner"
}

vx_compose_secret_add() {
    vx_compose_secret_install "$1" "$2" "$3" "$4" add
}

vx_compose_secret_change() {
    vx_compose_secret_install "$1" "$2" "$3" "$4" change
}

vx_compose_secret_delete() {
    local owner="$1"
    local project="$2"
    local name="$3"
    local root metadata temp_file referenced

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_secret_name_is_valid "$name" \
        || {
            vx_compose_error 'invalid Compose secret name'
            return 1
        }
    root="$(vx_compose_project_root "$owner" "$project")"
    vx_compose_lock_acquire "$owner" "$project" || return 1
    referenced="$(jq -r --arg name "$name" \
        '((.secrets // {})[$name] != null)' \
        "$root/runtime/canonical.json")" \
        || {
            vx_compose_error 'stored Compose secret references are invalid'
            vx_compose_lock_release
            return 1
        }
    [[ "$referenced" == true || "$referenced" == false ]] \
        || {
            vx_compose_error 'stored Compose secret references are invalid'
            vx_compose_lock_release
            return 1
        }
    if [[ "$referenced" == true ]]; then
        vx_compose_error 'Compose secret is referenced by the current revision'
        vx_compose_lock_release
        return 1
    fi
    rm -f -- "$(vx_compose_secret_path "$owner" "$project" "$name")"
    metadata="$(vx_compose_secret_metadata_path "$owner" "$project")"
    if [[ -f "$metadata" ]]; then
        temp_file="$(mktemp "$root/.secrets.XXXXXX")"
        jq -S --arg name "$name" 'del(.[$name])' "$metadata" >"$temp_file"
        chmod 0600 "$temp_file"
        mv -f -- "$temp_file" "$metadata"
    fi
    vx_compose_audit "$root" secret-delete succeeded
    vx_compose_lock_release
    vx_compose_refresh_counters "$owner"
}

vx_compose_secret_list_json() {
    local owner="$1"
    local project="$2"
    local metadata

    vx_compose_require_project "$owner" "$project" || return 1
    metadata="$(vx_compose_secret_metadata_path "$owner" "$project")"
    [[ -f "$metadata" ]] || {
        printf '%s\n' '{}'
        return
    }
    jq -S . "$metadata"
}

vx_compose_age_encrypt() {
    local input_file="$1"
    local output_file="$2"
    local recipient="${VX_DOCKER_AGE_RECIPIENT:-}"
    local temp_file

    command -v age >/dev/null 2>&1 \
        || {
            vx_compose_error 'age encryption is not installed'
            return 1
        }
    [[ "$recipient" =~ ^age1[0-9a-z]{20,}$ ]] \
        || {
            vx_compose_error 'age encryption recipient is not configured'
            return 1
        }
    temp_file="$(mktemp "${output_file}.XXXXXX")"
    if age --encrypt --recipient "$recipient" \
        --output "$temp_file" "$input_file" >/dev/null 2>&1; then
        chmod 0600 "$temp_file"
        mv -f -- "$temp_file" "$output_file"
    else
        rm -f -- "$temp_file"
        vx_compose_error 'age encryption self-test failed'
        return 1
    fi
}

vx_compose_age_decrypt() {
    local input_file="$1"
    local output_file="$2"
    local identity_file="${VX_DOCKER_AGE_IDENTITY_FILE:-}"
    local temp_file

    command -v age >/dev/null 2>&1 \
        || {
            vx_compose_error 'age decryption is not installed'
            return 1
        }
    [[ "$identity_file" == /*
        && -f "$identity_file"
        && ! -L "$identity_file"
        && "$(stat -c '%a' "$identity_file")" == 600
        && "$identity_file" != "$VESTA/data/users/"* ]] \
        || {
            vx_compose_error 'restore-required: age identity is not configured securely'
            return 1
        }
    if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$identity_file")" -ne 0 ]]; then
        vx_compose_error 'restore-required: age identity is not root-owned'
        return 1
    fi
    temp_file="$(mktemp "${output_file}.XXXXXX")" || return 1
    if age --decrypt --identity "$identity_file" \
        --output "$temp_file" "$input_file" >/dev/null 2>&1; then
        chmod 0600 "$temp_file"
        mv -f -- "$temp_file" "$output_file"
    else
        rm -f -- "$temp_file"
        vx_compose_error 'encrypted secret payload decryption failed'
        return 1
    fi
}
