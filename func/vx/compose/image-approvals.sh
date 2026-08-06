#!/usr/bin/env bash

VX_COMPOSE_IMAGE_APPROVAL_SCHEMA_VERSION='1'

vx_compose_image_approval_root() {
    printf '%s/data/vx/compose/image-approvals\n' "$VESTA"
}

vx_compose_image_approval_owner_root() {
    printf '%s/%s\n' "$(vx_compose_image_approval_root)" "$1"
}

vx_compose_image_approval_path() {
    local owner="$1" image_id="$2" profile="$3" profile_version="$4"

    vx_compose_owner_is_valid "$owner" || return 1
    [[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    [[ "$profile" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
    [[ "$profile_version" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s/%s.%s.v%s.json\n' \
        "$(vx_compose_image_approval_owner_root "$owner")" \
        "${image_id#sha256:}" "$profile" "$profile_version"
}

vx_compose_image_approval_actor_require_admin() {
    [[ "$1" == admin ]] || {
        vx_compose_error 'local image approval requires administrator authority'
        return 1
    }
}

vx_compose_image_approval_expiry_validate() {
    local expires="$1" expires_epoch now

    [[ "$expires" \
        =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || {
            vx_compose_error 'local image approval expiry must be a UTC timestamp'
            return 1
        }
    expires_epoch="$(date -u -d "$expires" +%s 2>/dev/null)" || {
        vx_compose_error 'local image approval expiry is invalid'
        return 1
    }
    now="$(date -u +%s)"
    (( expires_epoch > now && expires_epoch <= now + 31536000 )) || {
        vx_compose_error \
            'local image approval expiry must be within the next year'
        return 1
    }
}

vx_compose_image_approval_record_is_valid() {
    local path="$1"

    vx_compose_control_file_is_secure "$path" 600 || return 1
    jq -e --argjson schema "$VX_COMPOSE_IMAGE_APPROVAL_SCHEMA_VERSION" '
        type == "object"
        and keys == ["ACTOR","APPROVED","ARCHITECTURE","EXPIRES","IMAGE_ID",
                     "OS","OWNER","POLICY_SCHEMA","PROFILE","PROFILE_VERSION",
                     "REFERENCE","SCHEMA","VALIDATOR_VERSION"]
        and .SCHEMA == $schema
        and .ACTOR == "admin"
        and (.OWNER | type == "string"
            and test("^[a-z0-9][a-z0-9_-]{0,31}$"))
        and (.REFERENCE | type == "string" and length > 0 and length <= 255
            and test("^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$")
            and (contains("://") | not) and (contains("..") | not))
        and (.IMAGE_ID | type == "string"
            and test("^sha256:[a-f0-9]{64}$"))
        and .OS == "linux"
        and (.ARCHITECTURE | IN("amd64","arm64"))
        and (.PROFILE | type == "string"
            and test("^[a-z][a-z0-9-]{0,31}$"))
        and (.PROFILE_VERSION | type == "number" and floor == . and . > 0)
        and (.POLICY_SCHEMA | type == "number" and floor == . and . > 0)
        and (.VALIDATOR_VERSION | type == "number" and floor == . and . > 0)
        and (.APPROVED | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (.EXPIRES | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$path" >/dev/null 2>&1
}

vx_compose_image_approval_audit() {
    local owner="$1" action="$2" image_id="$3"
    local profile="$4" profile_version="$5"

    vx_compose_owner_audit "$owner" "image-approval-$action" succeeded \
        "image_id=$image_id profile=$profile profile_version=$profile_version"
}

vx_compose_image_approval_add() {
    local actor="$1" owner="$2" reference="$3" image_id="$4"
    local image_os="$5" architecture="$6" profile="$7"
    local profile_version="$8" expires="$9"
    local installed_profile_version inspection inspected_id inspected_os
    local inspected_architecture approval_root owner_root path temp_file
    local expected_uid expected_gid

    vx_compose_image_approval_actor_require_admin "$actor" || return 1
    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_reference_is_valid "$reference" || {
        vx_compose_error 'invalid Docker image reference'
        return 1
    }
    [[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || {
        vx_compose_error 'invalid local Docker image ID'
        return 1
    }
    [[ "$image_os" == linux && "$architecture" =~ ^(amd64|arm64)$ ]] || {
        vx_compose_error 'invalid local Docker image platform'
        return 1
    }
    vx_compose_profile_is_available "$profile" || {
        vx_compose_error 'Compose profile is not available'
        return 1
    }
    [[ "$profile_version" =~ ^[1-9][0-9]*$ ]] || {
        vx_compose_error 'invalid Compose profile version'
        return 1
    }
    installed_profile_version="$(vx_compose_profile_version "$profile")" \
        || return 1
    [[ "$profile_version" == "$installed_profile_version" ]] || {
        vx_compose_error 'Compose profile version is not installed'
        return 1
    }
    vx_compose_image_approval_expiry_validate "$expires" || return 1
    vx_compose_image_identity_is_recorded "$owner" "$reference" "$image_id" \
        || {
            vx_compose_error 'local Docker image identity was not recorded'
            return 1
        }
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || return 1
    inspected_id="$(jq -er '.Id' <<<"$inspection")" || return 1
    inspected_os="$(jq -er '.Os' <<<"$inspection")" || return 1
    inspected_architecture="$(jq -er '.Architecture' <<<"$inspection")" \
        || return 1
    [[ "$inspected_id" == "$image_id"
        && "$inspected_os" == "$image_os"
        && "$inspected_architecture" == "$architecture" ]] || {
        vx_compose_error 'local Docker image identity does not match inspection'
        return 1
    }

    approval_root="$(vx_compose_image_approval_root)" || return 1
    owner_root="$(vx_compose_image_approval_owner_root "$owner")" || return 1
    path="$(vx_compose_image_approval_path \
        "$owner" "$image_id" "$profile" "$profile_version")" || return 1
    [[ ! -e "$approval_root" || (-d "$approval_root" && ! -L "$approval_root") ]] \
        && [[ ! -e "$owner_root" || (-d "$owner_root" && ! -L "$owner_root") ]] \
        || {
            vx_compose_error 'local image approval storage is unsafe'
            return 1
        }
    install -d -m 0700 "$approval_root" "$owner_root" || return 1
    expected_uid="$(vx_compose_authority_uid)" || return 1
    expected_gid="$(vx_compose_authority_gid)" || return 1
    [[ "$(stat -c '%u:%g:%a:%F' "$approval_root" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700:directory"
        && "$(stat -c '%u:%g:%a:%F' "$owner_root" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700:directory" ]] || {
        vx_compose_error 'local image approval storage is unsafe'
        return 1
    }
    temp_file="$(mktemp "$owner_root/.approval.XXXXXX")" || return 1
    if ! jq -n -S \
        --argjson schema "$VX_COMPOSE_IMAGE_APPROVAL_SCHEMA_VERSION" \
        --arg actor "$actor" \
        --arg owner "$owner" \
        --arg reference "$reference" \
        --arg image_id "$image_id" \
        --arg image_os "$image_os" \
        --arg architecture "$architecture" \
        --arg profile "$profile" \
        --argjson profile_version "$profile_version" \
        --argjson policy_schema "$VX_COMPOSE_POLICY_SCHEMA_VERSION" \
        --argjson validator_version "$VX_COMPOSE_POLICY_VALIDATOR_VERSION" \
        --arg approved "$(vx_compose_now)" \
        --arg expires "$expires" '{
            SCHEMA: $schema,
            ACTOR: $actor,
            OWNER: $owner,
            REFERENCE: $reference,
            IMAGE_ID: $image_id,
            OS: $image_os,
            ARCHITECTURE: $architecture,
            PROFILE: $profile,
            PROFILE_VERSION: $profile_version,
            POLICY_SCHEMA: $policy_schema,
            VALIDATOR_VERSION: $validator_version,
            APPROVED: $approved,
            EXPIRES: $expires
        }' >"$temp_file" \
        || ! vx_compose_control_file_protect "$temp_file" 600 \
        || ! mv -f -- "$temp_file" "$path"; then
        rm -f -- "$temp_file"
        return 1
    fi
    vx_compose_image_approval_audit \
        "$owner" added "$image_id" "$profile" "$profile_version" || return 1
    printf '%s\n' "$path"
}

vx_compose_image_approval_require() {
    local owner="$1" reference="$2" image_id="$3" image_os="$4"
    local architecture="$5" profile="$6" profile_version="$7"
    local path expires expires_epoch inspection

    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_reference_is_valid "$reference" || return 1
    path="$(vx_compose_image_approval_path \
        "$owner" "$image_id" "$profile" "$profile_version")" || return 1
    vx_compose_image_approval_record_is_valid "$path" || {
        vx_compose_error 'valid local image approval is required'
        return 1
    }
    jq -e \
        --arg owner "$owner" \
        --arg reference "$reference" \
        --arg image_id "$image_id" \
        --arg image_os "$image_os" \
        --arg architecture "$architecture" \
        --arg profile "$profile" \
        --argjson profile_version "$profile_version" \
        --argjson policy_schema "$VX_COMPOSE_POLICY_SCHEMA_VERSION" \
        --argjson validator_version "$VX_COMPOSE_POLICY_VALIDATOR_VERSION" '
            .OWNER == $owner
            and .REFERENCE == $reference
            and .IMAGE_ID == $image_id
            and .OS == $image_os
            and .ARCHITECTURE == $architecture
            and .PROFILE == $profile
            and .PROFILE_VERSION == $profile_version
            and .POLICY_SCHEMA == $policy_schema
            and .VALIDATOR_VERSION == $validator_version
        ' "$path" >/dev/null || {
        vx_compose_error 'local image approval does not match current authority'
        return 1
    }
    [[ "$(vx_compose_profile_version "$profile")" == "$profile_version" ]] \
        && vx_compose_profile_is_available "$profile" || {
        vx_compose_error 'local image approval profile is unavailable'
        return 1
    }
    expires="$(jq -er '.EXPIRES' "$path")" || return 1
    expires_epoch="$(date -u -d "$expires" +%s 2>/dev/null)" || return 1
    (( expires_epoch > $(date -u +%s) )) || {
        vx_compose_error 'local image approval has expired'
        return 1
    }
    vx_compose_image_identity_is_recorded "$owner" "$reference" "$image_id" \
        || {
            vx_compose_error 'approved local Docker image record is unavailable'
            return 1
        }
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || return 1
    jq -e \
        --arg image_id "$image_id" \
        --arg image_os "$image_os" \
        --arg architecture "$architecture" '
            .Id == $image_id
            and .Os == $image_os
            and .Architecture == $architecture
        ' <<<"$inspection" >/dev/null || {
        vx_compose_error 'approved local Docker image identity has changed'
        return 1
    }
    return 0
}

vx_compose_image_approval_delete() {
    local actor="$1" owner="$2" image_id="$3" profile="$4"
    local profile_version="$5" owner_root path

    vx_compose_image_approval_actor_require_admin "$actor" || return 1
    vx_compose_require_owner "$owner" || return 1
    path="$(vx_compose_image_approval_path \
        "$owner" "$image_id" "$profile" "$profile_version")" || {
        vx_compose_error 'invalid local image approval identity'
        return 1
    }
    owner_root="$(vx_compose_image_approval_owner_root "$owner")" || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        vx_compose_image_approval_record_is_valid "$path" || {
            vx_compose_error 'local image approval record is unsafe'
            return 1
        }
        rm -f -- "$path" || return 1
    fi
    rmdir -- "$owner_root" 2>/dev/null || true
    vx_compose_image_approval_audit \
        "$owner" deleted "$image_id" "$profile" "$profile_version"
}
