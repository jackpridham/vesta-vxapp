#!/usr/bin/env bash

vx_compose_preview_root() {
    printf '%s/data/tmp/compose-previews\n' "$VESTA"
}

vx_compose_preview_expected_uid() {
    printf '0\n'
}

vx_compose_preview_expected_gid() {
    printf '0\n'
}

vx_compose_preview_install() {
    command install -o 0 -g 0 "$@"
}

vx_compose_preview_set_ownership() {
    chown 0:0 "$@"
}

vx_compose_preview_consume_web_source() {
    local source="$1" parent="$2"
    local expected_source_identity="$3" expected_parent_identity="$4"
    local source_identity parent_identity

    source_identity="$(stat -c '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' \
        "$source" 2>/dev/null)" || source_identity=
    parent_identity="$(stat -c '%d:%i:%u:%g:%a:%F:%Y:%Z' \
        "$parent" 2>/dev/null)" || parent_identity=
    if [[ "$source_identity" != "$expected_source_identity"
        || "$parent_identity" != "$expected_parent_identity" ]]; then
        vx_compose_error \
            'trusted web source identity changed; cleanup retained'
        return 1
    fi
    rm -f -- "$source" || {
        vx_compose_error 'trusted web source cleanup failed'
        return 1
    }
    rmdir -- "$parent" 2>/dev/null || {
        vx_compose_error \
            'trusted web source cleanup retained unexpected contents'
        return 1
    }
}

vx_compose_actor_can_manage_profile() {
    local actor="$1" owner="$2" profile="$3"
    local project="${4:-}" mode="${5:-}"

    vx_compose_require_owner "$owner" || return 1
    [[ "$profile" == standard ]] || return 1
    [[ "$actor" == admin || "$actor" == "$owner" ]] && return 0
    [[ "$mode" == change && -n "$project" ]] || return 1
    vx_compose_authorize "$actor" "$owner" "$project" deploy
}

vx_compose_preview_id_is_valid() {
    [[ "$1" =~ ^[a-f0-9]{32}$ ]]
}

vx_compose_preview_metadata_is_valid() {
    local preview="$1" preview_id="$2" metadata
    local key value expires source_sha candidate_sha policy_sha
    local -A seen=() values=()

    metadata="$preview/preview.conf"
    [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] || return 1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen["$key"]=1
        values["$key"]="$value"
        case "$key" in
            ACTOR|OWNER)
                [[ "$value" == admin \
                    || "$value" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
                ;;
            PROJECT) [[ "$value" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1 ;;
            PROFILE) [[ "$value" == standard ]] || return 1 ;;
            MODE) [[ "$value" == add || "$value" == change ]] || return 1 ;;
            SOURCE_SHA256|CANDIDATE_SHA256|POLICY_SHA256)
                [[ "$value" =~ ^[a-f0-9]{64}$ ]] || return 1
                ;;
            EXPECTED_CURRENT_REVISION|CREATED_EPOCH|EXPIRES_EPOCH)
                [[ "$value" =~ ^[0-9]+$ ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done <"$metadata"
    [[ "${#seen[@]}" -eq 11 ]] || return 1
    for key in ACTOR OWNER PROJECT PROFILE MODE SOURCE_SHA256 \
        CANDIDATE_SHA256 POLICY_SHA256 EXPECTED_CURRENT_REVISION \
        CREATED_EPOCH EXPIRES_EPOCH; do
        [[ -n "${seen[$key]+x}" ]] || return 1
    done
    [[ "${values[ACTOR]}" == admin \
        || "${values[ACTOR]}" == "${values[OWNER]}" ]] || return 1
    if [[ "${values[MODE]}" == add ]]; then
        [[ "${values[EXPECTED_CURRENT_REVISION]}" == 0 ]] || return 1
    else
        [[ "${values[EXPECTED_CURRENT_REVISION]}" =~ ^[1-9][0-9]*$ ]] \
            || return 1
    fi
    (( 10#${values[EXPIRES_EPOCH]} > 10#${values[CREATED_EPOCH]}
        && 10#${values[EXPIRES_EPOCH]}
            - 10#${values[CREATED_EPOCH]} == 900 )) \
        || return 1
    source_sha="$(sha256sum "$preview/source.compose.yaml" | awk '{print $1}')" \
        || return 1
    candidate_sha="$(sha256sum "$preview/canonical.json" | awk '{print $1}')" \
        || return 1
    policy_sha="$(sha256sum "$preview/policy.conf" | awk '{print $1}')" \
        || return 1
    [[ "$source_sha" == "${values[SOURCE_SHA256]}"
        && "$candidate_sha" == "${values[CANDIDATE_SHA256]}"
        && "$policy_sha" == "${values[POLICY_SHA256]}" ]] || return 1
    vx_compose_preview_id_is_valid "$preview_id" || return 1
    expires="$(vx_compose_meta_get "$metadata" EXPIRES_EPOCH)" || return 1
    printf '%s\n' "$expires"
}

vx_compose_preview_contents_are_valid() {
    local preview="$1" expected_uid="$2" expected_gid="$3"
    local entry name count=0

    while IFS= read -r -d '' entry; do
        count=$((count + 1))
        [[ -f "$entry" && ! -L "$entry"
            && "$(stat -c '%u:%g:%a' "$entry" 2>/dev/null)" \
                == "$expected_uid:$expected_gid:600" ]] || return 1
        name="$(basename -- "$entry")"
        case "$name" in
            source.compose.yaml|compose.yaml|canonical.json|canonical.sha256|\
                policy.conf|\
                manifest.sha256|preview.conf)
                ;;
            *) return 1 ;;
        esac
    done < <(find "$preview" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    [[ "$count" -eq 7 ]] || return 1
    (
        cd "$preview" || exit 1
        [[ "$(awk '{print $2}' manifest.sha256 | paste -sd ' ' -)" \
            == 'source.compose.yaml compose.yaml canonical.json canonical.sha256 policy.conf' ]]
        [[ "$(awk '{print $2}' canonical.sha256)" == 'canonical.json' ]]
        sha256sum -c canonical.sha256 >/dev/null 2>&1
        sha256sum -c manifest.sha256 >/dev/null 2>&1
    )
}

vx_compose_preview_quarantine() {
    local preview="$1" preview_id="$2" preview_root target

    preview_root="$(vx_compose_preview_root)"
    [[ "$preview" == "$preview_root/$preview_id"
        && "$preview_id" =~ ^[a-f0-9]{32}$
        && -e "$preview" && ! -L "$preview" ]] || return 1
    target="$preview_root/.rejected-$preview_id-$(date +%s)"
    [[ ! -e "$target" && ! -L "$target" ]] || return 1
    mv -- "$preview" "$target"
}

vx_compose_preview_verify() {
    local actor="$1" owner="$2" project="$3" preview_id="$4"
    local source_sha="$5" candidate_sha="$6" expected_revision="$7"
    local preview_root preview resolved parent expected_uid expected_gid
    local metadata expires now profile mode stored_policy_sha

    vx_compose_preview_id_is_valid "$preview_id" || return 1
    vx_compose_require_project_key "$project" || return 1
    [[ "$source_sha" =~ ^[a-f0-9]{64}$
        && "$candidate_sha" =~ ^[a-f0-9]{64}$
        && "$expected_revision" =~ ^[0-9]+$ ]] || return 1
    preview_root="$(vx_compose_preview_root)"
    preview="$preview_root/$preview_id"
    [[ -d "$preview_root" && ! -L "$preview_root"
        && -d "$preview" && ! -L "$preview" ]] || return 1
    resolved="$(readlink -f -- "$preview")" || return 1
    parent="$(dirname -- "$resolved")"
    [[ "$resolved" == "$preview" && "$parent" == "$preview_root" ]] || return 1
    expected_uid="$(vx_compose_preview_expected_uid)" || return 1
    expected_gid="$(vx_compose_preview_expected_gid)" || return 1
    [[ "$(stat -c '%u:%g:%a:%F' "$preview_root" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700:directory"
        && "$(stat -c '%u:%g:%a:%F' "$preview" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700:directory" ]] || return 1
    vx_compose_preview_contents_are_valid \
        "$preview" "$expected_uid" "$expected_gid" || return 1
    metadata="$preview/preview.conf"
    awk -F= '
      !/^(ACTOR|OWNER|PROJECT|PROFILE|MODE|SOURCE_SHA256|CANDIDATE_SHA256|POLICY_SHA256|EXPECTED_CURRENT_REVISION|CREATED_EPOCH|EXPIRES_EPOCH)=/ {
        exit 1
      }
    ' "$metadata" || return 1
    vx_compose_preview_metadata_is_valid "$preview" "$preview_id" >/dev/null \
        || return 1
    [[ "$(vx_compose_meta_get "$metadata" ACTOR)" == "$actor"
        && "$(vx_compose_meta_get "$metadata" OWNER)" == "$owner"
        && "$(vx_compose_meta_get "$metadata" PROJECT)" == "$project"
        && "$(vx_compose_meta_get "$metadata" SOURCE_SHA256)" == "$source_sha"
        && "$(vx_compose_meta_get "$metadata" CANDIDATE_SHA256)" == "$candidate_sha"
        && "$(vx_compose_meta_get "$metadata" EXPECTED_CURRENT_REVISION)" \
            == "$expected_revision" ]] || return 1
    profile="$(vx_compose_meta_get "$metadata" PROFILE)" || return 1
    mode="$(vx_compose_meta_get "$metadata" MODE)" || return 1
    vx_compose_actor_can_manage_profile \
        "$actor" "$owner" "$profile" "$project" "$mode" || return 1
    [[ "$profile" == standard && ( "$mode" == add || "$mode" == change ) ]] \
        || return 1
    expires="$(vx_compose_meta_get "$metadata" EXPIRES_EPOCH)" || return 1
    now="$(date +%s)"
    (( 10#$expires > now )) || return 1
    [[ "$(sha256sum "$preview/source.compose.yaml" | awk '{print $1}')" \
            == "$source_sha"
        && "$(sha256sum "$preview/canonical.json" | awk '{print $1}')" \
            == "$candidate_sha"
        && "$(awk 'NR == 1 {print $1}' "$preview/canonical.sha256")" \
            == "$candidate_sha" ]] || return 1
    stored_policy_sha="$(vx_compose_meta_get "$metadata" POLICY_SHA256)" \
        || return 1
    [[ "$(sha256sum "$preview/policy.conf" | awk '{print $1}')" \
        == "$stored_policy_sha" ]] || return 1
    printf '%s\n' "$preview"
}

vx_compose_preview_apply() {
    local actor="$1" owner="$2" project="$3" preview_id="$4"
    local source_sha="$5" candidate_sha="$6" expected_revision="$7"
    local preview_root preview='' verified='' metadata mode current root
    local result=1 actor_pushed=no

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    vx_compose_actor_is_active "$actor" || return 1
    preview_root="$(vx_compose_preview_root)"
    preview="$preview_root/$preview_id"
    vx_compose_lock_acquire "$owner" "$project" || return 1
    if ! verified="$(vx_compose_preview_verify \
        "$actor" "$owner" "$project" "$preview_id" "$source_sha" \
        "$candidate_sha" "$expected_revision")"; then
        if [[ -d "$preview" && ! -L "$preview" ]] \
            && { ! vx_compose_preview_contents_are_valid \
                    "$preview" "$(vx_compose_preview_expected_uid)" \
                    "$(vx_compose_preview_expected_gid)" \
                || ! vx_compose_preview_metadata_is_valid \
                    "$preview" "$preview_id" >/dev/null 2>&1; }; then
            vx_compose_preview_quarantine "$preview" "$preview_id" || :
        fi
    else
        metadata="$verified/preview.conf"
        mode="$(vx_compose_meta_get "$metadata" MODE)" || mode=
        root="$(vx_compose_project_root "$owner" "$project")"
        if [[ "$mode" == add ]]; then
            [[ "$expected_revision" == 0 && ! -e "$root" ]] || mode=
        elif [[ "$mode" == change ]] && vx_compose_require_project \
            "$owner" "$project"; then
            current="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
                || current=
            [[ "$current" == "$expected_revision" ]] || mode=
        else
            mode=
        fi
        if [[ -n "$mode" ]] \
            && vx_compose_audit_actor_push "$actor"; then
            actor_pushed=yes
            if [[ "$mode" == change ]]; then
                vx_compose_transaction_update \
                    "$owner" "$project" "$verified" "$expected_revision" \
                    && result=0
            elif vx_compose_store_new \
                "$owner" "$project" standard "$verified"; then
                if vx_compose_deploy "$owner" "$project"; then
                    result=0
                else
                    vx_compose_audit \
                        "$(vx_compose_project_root "$owner" "$project")" \
                        preview-apply failed \
                        'candidate convergence failed; removing incomplete project' \
                        || :
                    if ! vx_compose_remove \
                        "$owner" "$project" >/dev/null 2>&1; then
                        root="$(vx_compose_project_root "$owner" "$project")"
                        if [[ -d "$root" && ! -L "$root" ]]; then
                            vx_compose_update_state \
                                "$owner" "$project" cleanup-required || :
                            vx_compose_audit "$root" preview-cleanup failed \
                                'scoped runtime teardown incomplete; control metadata retained' \
                                || :
                        fi
                    fi
                fi
            fi
        fi
    fi
    if [[ "$result" -eq 0 ]]; then
        [[ "$verified" == "$preview_root/$preview_id"
            && -d "$verified" && ! -L "$verified" ]] \
            && rm -rf -- "$verified"
    fi
    [[ "$actor_pushed" == no ]] || vx_compose_audit_actor_pop
    vx_compose_lock_release
    return "$result"
}

vx_compose_preview_gc() {
    local preview_root preview preview_id expires now invalid
    local expected_uid expected_gid

    preview_root="$(vx_compose_preview_root)"
    [[ ! -e "$preview_root" ]] && return 0
    expected_uid="$(vx_compose_preview_expected_uid)" || return 1
    expected_gid="$(vx_compose_preview_expected_gid)" || return 1
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] \
        || return 1
    [[ -d "$preview_root" && ! -L "$preview_root"
        && "$(stat -c '%u:%g:%a' "$preview_root" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700" ]] || {
        vx_compose_error 'Compose preview root is invalid'
        return 1
    }
    now="$(date +%s)"
    while IFS= read -r -d '' preview; do
        preview_id="$(basename -- "$preview")"
        invalid=no
        vx_compose_preview_id_is_valid "$preview_id" || invalid=yes
        [[ -d "$preview" && ! -L "$preview"
            && "$(stat -c '%u:%g:%a' "$preview" 2>/dev/null)" \
                == "$expected_uid:$expected_gid:700" ]] \
            || invalid=yes
        [[ "$invalid" == yes ]] \
            || vx_compose_preview_contents_are_valid \
                "$preview" "$expected_uid" "$expected_gid" || invalid=yes
        if [[ "$invalid" == yes ]]; then
            vx_compose_error \
                "invalid Compose preview retained for administrator inspection: $preview_id" \
                || :
            continue
        fi
        expires="$(vx_compose_preview_metadata_is_valid \
            "$preview" "$preview_id" 2>/dev/null)" || expires=
        if [[ ! "$expires" =~ ^[0-9]+$ ]]; then
            vx_compose_error \
                "invalid Compose preview retained for administrator inspection: $preview_id" \
                || :
            continue
        fi
        if (( expires <= now )); then
            rm -rf -- "$preview"
        fi
    done < <(find "$preview_root" -mindepth 1 -maxdepth 1 -print0)
}

vx_compose_preview_stage() (
    local actor="$1" owner="$2" project="$3" source="$4"
    local profile="$5" mode="$6"
    local preview_parent preview_id preview candidate source_parent=
    local source_sha copy_sha candidate_sha policy_sha diagnostics
    local source_identity_validated source_identity_after
    local source_parent_identity_validated
    local expected_uid expected_gid preview_identity
    local current_profile current_revision created_epoch expires_epoch expires_at
    local plan manifest_temp metadata_temp result=1

    umask 077
    vx_compose_require_project_key "$project" || return 1
    [[ "$mode" == add || "$mode" == change ]] || {
        vx_compose_error 'invalid Compose preview mode'
        return 1
    }
    vx_compose_actor_can_manage_profile \
        "$actor" "$owner" "$profile" "$project" "$mode" \
        || {
            vx_compose_error 'actor is not authorized for the Compose profile'
            return 1
        }
    vx_compose_web_source_validate "$source" compose.yaml || return 1
    source_parent="$VX_COMPOSE_WEB_SOURCE_PARENT"
    source_identity_validated="$(stat -c \
        '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' "$source")" || return 1
    source_parent_identity_validated="$(stat -c \
        '%d:%i:%u:%g:%a:%F:%Y:%Z' "$source_parent")" || return 1
    trap '
        if [[ -n "${source_parent:-}" ]]; then
            vx_compose_preview_consume_web_source \
                "$source" "$source_parent" "$source_identity_validated" \
                "$source_parent_identity_validated" || :
        fi
        if [[ "${result:-1}" -ne 0 && -n "${preview:-}"
            && "$preview" == "$preview_parent/$preview_id"
            && "$preview_id" =~ ^[a-f0-9]{32}$
            && -d "$preview" && ! -L "$preview" ]]; then
            preview_identity="$(stat -c "%u:%g:%a" "$preview" 2>/dev/null)" \
                || preview_identity=
            if [[ "$preview_identity" \
                == "$expected_uid:$expected_gid:700" ]]; then
                rm -rf -- "$preview"
            else
                vx_compose_error \
                    "incomplete Compose preview retained for administrator inspection" \
                    || :
            fi
        fi
    ' EXIT

    preview_parent="$(vx_compose_preview_root)"
    expected_uid="$(vx_compose_preview_expected_uid)" || return 1
    expected_gid="$(vx_compose_preview_expected_gid)" || return 1
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] \
        || return 1
    vx_compose_preview_install -d -m 0700 "$preview_parent" || return 1
    vx_compose_preview_gc || return 1
    preview_id="$(openssl rand -hex 16)" || return 1
    vx_compose_preview_id_is_valid "$preview_id" || return 1
    preview="$preview_parent/$preview_id"
    [[ ! -e "$preview" && ! -L "$preview" ]] || {
        vx_compose_error 'generated Compose preview identifier is unavailable'
        return 1
    }
    vx_compose_preview_install -d -m 0700 "$preview" || return 1

    source_identity_after="$(stat -c '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' \
        "$source")" || return 1
    [[ "$source_identity_validated" == "$source_identity_after" ]] || return 1
    cp --no-dereference -- "$source" "$preview/source.compose.yaml" \
        || return 1
    [[ -f "$preview/source.compose.yaml" \
        && ! -L "$preview/source.compose.yaml" ]] \
        || return 1
    vx_compose_preview_set_ownership "$preview/source.compose.yaml" \
        || return 1
    chmod 0600 "$preview/source.compose.yaml" || return 1
    source_identity_after="$(stat -c '%d:%i:%u:%g:%a:%F:%s:%Y:%Z' \
        "$source")" || return 1
    [[ "$source_identity_validated" == "$source_identity_after" ]] || return 1
    copy_sha="$(sha256sum "$preview/source.compose.yaml" | awk '{print $1}')" \
        || return 1
    source_sha="$copy_sha"
    [[ "$source_sha" =~ ^[a-f0-9]{64}$ ]] || {
        vx_compose_error 'protected Compose source changed during staging'
        return 1
    }
    vx_compose_preview_consume_web_source \
        "$source" "$source_parent" "$source_identity_validated" \
        "$source_parent_identity_validated" || return 1
    source_parent=

    vx_compose_lock_acquire "$owner" "$project" || return 1
    if [[ "$mode" == add ]]; then
        if [[ -e "$(vx_compose_project_root "$owner" "$project")" ]]; then
            vx_compose_lock_release
            vx_compose_error 'Compose project already exists'
            return 1
        fi
        current_revision=0
    elif ! vx_compose_require_project "$owner" "$project"; then
        vx_compose_lock_release
        return 1
    else
        current_profile="$(vx_compose_meta_get \
            "$(vx_compose_project_root "$owner" "$project")/project.conf" \
            PROFILE)" || {
            vx_compose_lock_release
            return 1
        }
        current_revision="$(vx_compose_meta_get \
            "$(vx_compose_project_root "$owner" "$project")/project.conf" \
            REVISION)" || {
            vx_compose_lock_release
            return 1
        }
        if [[ "$current_profile" != "$profile"
            || ! "$current_revision" =~ ^[1-9][0-9]*$ ]]; then
            vx_compose_lock_release
            vx_compose_error 'stored Compose profile or revision does not match'
            return 1
        fi
    fi
    vx_compose_lock_release

    candidate="$preview/.candidate"
    diagnostics="$preview/.prepare.stderr"
    : >"$diagnostics" || return 1
    chmod 0600 "$diagnostics" || return 1
    if ! vx_compose_prepare_candidate \
        "$owner" "$project" "$preview/source.compose.yaml" "$candidate" \
        "$profile" no '' '' preview 2>"$diagnostics"; then
        rm -f -- "$diagnostics"
        vx_compose_error 'Compose candidate preparation failed'
        return 1
    fi
    rm -f -- "$diagnostics" || return 1
    plan="$(vx_compose_candidate_deployment_plan_json \
        "$owner" "$project" "$profile" "$candidate" "$mode" \
        "$source_sha")" || return 1
    candidate_sha="$(vx_compose_candidate_sha "$candidate")" || return 1
    policy_sha="$(sha256sum "$candidate/policy.conf" | awk '{print $1}')" \
        || return 1
    [[ "$candidate_sha" =~ ^[a-f0-9]{64}$
        && "$policy_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    vx_compose_preview_install -m 0600 \
        "$candidate/compose.yaml" "$preview/compose.yaml" || return 1
    vx_compose_preview_install -m 0600 \
        "$candidate/canonical.json" "$preview/canonical.json" || return 1
    vx_compose_preview_install -m 0600 \
        "$candidate/canonical.sha256" "$preview/canonical.sha256" || return 1
    vx_compose_preview_install -m 0600 \
        "$candidate/policy.conf" "$preview/policy.conf" || return 1
    rm -rf -- "$candidate" || return 1

    created_epoch="$(date +%s)"
    expires_epoch=$((created_epoch + 900))
    expires_at="$(date -u -d "@$expires_epoch" +'%Y-%m-%dT%H:%M:%SZ')"
    metadata_temp="$preview/.preview.conf.tmp"
    {
        printf "ACTOR='%s'\n" "$actor"
        printf "OWNER='%s'\n" "$owner"
        printf "PROJECT='%s'\n" "$project"
        printf "PROFILE='%s'\n" "$profile"
        printf "MODE='%s'\n" "$mode"
        printf "SOURCE_SHA256='%s'\n" "$source_sha"
        printf "CANDIDATE_SHA256='%s'\n" "$candidate_sha"
        printf "POLICY_SHA256='%s'\n" "$policy_sha"
        printf "EXPECTED_CURRENT_REVISION='%s'\n" "$current_revision"
        printf "CREATED_EPOCH='%s'\n" "$created_epoch"
        printf "EXPIRES_EPOCH='%s'\n" "$expires_epoch"
    } >"$metadata_temp" || return 1
    chmod 0600 "$metadata_temp" || return 1
    mv -f -- "$metadata_temp" "$preview/preview.conf" || return 1

    manifest_temp="$preview/.manifest.sha256.tmp"
    (
        cd "$preview" || exit 1
        sha256sum source.compose.yaml compose.yaml canonical.json \
            canonical.sha256 policy.conf
    ) >"$manifest_temp" || return 1
    chmod 0600 "$manifest_temp" || return 1
    mv -f -- "$manifest_temp" "$preview/manifest.sha256" || return 1
    vx_compose_preview_set_ownership "$preview"/* || return 1
    chmod 0600 "$preview"/* || return 1

    jq -S \
        --arg preview_id "$preview_id" \
        --arg expires_at "$expires_at" \
        --argjson expected_revision "$current_revision" '
        . + {
            PREVIEW_ID: $preview_id,
            EXPECTED_CURRENT_REVISION: $expected_revision,
            EXPIRES_AT: $expires_at
        }' <<<"$plan"
    result=0
)

vx_compose_snapshot_source_file() {
    local source_file="$1"
    local snapshot="$2"

    cp --no-dereference -- "$source_file" "$snapshot" || {
        rm -f -- "$snapshot"
        return 1
    }
    [[ -f "$snapshot" && ! -L "$snapshot" ]] || {
        rm -f -- "$snapshot"
        return 1
    }
    chmod 0600 "$snapshot" || {
        rm -f -- "$snapshot"
        return 1
    }
}

vx_compose_definition_contains_managed_secret() {
    local root="$1" source="$2" secret_file secret_line pattern_file
    local has_patterns=no scan_failed=no grep_status result=1

    [[ -d "$root/secrets" ]] || return 1
    pattern_file="$(mktemp \
        "${TMPDIR:-/tmp}/vx-compose-secret-patterns.XXXXXX")" || {
        vx_compose_error 'managed secret scan setup failed'
        return 0
    }
    if ! chmod 0600 "$pattern_file"; then
        rm -f -- "$pattern_file"
        vx_compose_error 'managed secret scan setup failed'
        return 0
    fi
    for secret_file in "$root"/secrets/*; do
        [[ -f "$secret_file" && ! -L "$secret_file" ]] || continue
        if [[ ! -r "$secret_file" ]]; then
            scan_failed=yes
            break
        fi
        while IFS= read -r secret_line || [[ -n "$secret_line" ]]; do
            [[ -n "$secret_line" ]] || continue
            if ! printf '%s\n' "$secret_line" >>"$pattern_file"; then
                scan_failed=yes
                break 2
            fi
            has_patterns=yes
        done <"$secret_file"
    done
    if [[ "$scan_failed" == yes ]]; then
        vx_compose_error 'managed secret scan failed'
        result=0
    elif [[ "$has_patterns" == yes ]]; then
        if grep -Fq -f "$pattern_file" -- "$source"; then
            result=0
        else
            grep_status=$?
            if [[ "$grep_status" -gt 1 ]]; then
                vx_compose_error 'managed secret scan failed'
                result=0
            fi
        fi
    fi
    rm -f -- "$pattern_file"
    return "$result"
}

vx_compose_definition_export_expected_uid() {
    printf '0\n'
}

vx_compose_prepare_candidate_quiet() {
    local diagnostics result=1

    diagnostics="$(mktemp \
        "${TMPDIR:-/tmp}/vx-compose-validation.XXXXXX")" || return 1
    if ! chmod 0600 "$diagnostics"; then
        rm -f -- "$diagnostics"
        return 1
    fi
    if vx_compose_prepare_candidate "$@" 2>"$diagnostics"; then
        result=0
    fi
    rm -f -- "$diagnostics" || return 1
    return "$result"
}

vx_compose_definition_write_editable() {
    local canonical="$1" output="$2"

    [[ -f "$canonical" && ! -L "$canonical" ]] || return 1
    jq -S '
        def strip_service_identity:
            .labels = ((.labels // {})
                | del(."vx.managed", ."vx.user", ."vx.project"))
            | if .labels == {} then del(.labels) else . end;
        def strip_network_identity:
            del(.name)
            | .labels = ((.labels // {})
                | del(
                    ."vx.managed", ."vx.user", ."vx.project",
                    ."vx.network"
                ))
            | if .labels == {} then del(.labels) else . end;
        def strip_volume_identity:
            del(.name)
            | .labels = ((.labels // {})
                | del(
                    ."vx.managed", ."vx.user", ."vx.project",
                    ."vx.volume"
                ))
            | if .labels == {} then del(.labels) else . end;

        del(.name)
        | .services |= with_entries(.value |= strip_service_identity)
        | .networks = ((.networks // {})
            | with_entries(.value |= strip_network_identity))
        | .volumes = ((.volumes // {})
            | with_entries(.value |= strip_volume_identity))
        | if .networks == {} then del(.networks) else . end
        | if .volumes == {} then del(.volumes) else . end
    ' "$canonical" >"$output" || return 1
    chmod 0600 "$output"
}

vx_compose_definition_export_json() {
    local owner="$1"
    local project="$2"
    local root source_file metadata profile revision
    local export_root copy_file candidate raw_candidate labeled_candidate
    local editable_candidate definition_file source_sha_before source_sha_after
    local definition_sha copy_sha expected_copy_uid result=1

    export_root=
    copy_file=
    candidate=
    definition_file=

    if ! vx_compose_owner_is_valid "$owner"; then
        vx_compose_error "invalid Compose project owner: $owner"
        return 1
    fi
    if ! vx_compose_project_is_valid "$project"; then
        vx_compose_error "invalid Compose project key: $project"
        return 1
    fi
    if ! vx_compose_lock_acquire "$owner" "$project"; then
        return 1
    fi

    root="$(vx_compose_project_root "$owner" "$project")"
    source_file="$root/compose.yaml"
    metadata="$root/project.conf"
    if ! vx_compose_require_project "$owner" "$project"; then
        :
    elif [[ ! -f "$source_file" || -L "$source_file"
        || "$(stat -c '%a' "$source_file" 2>/dev/null)" != 640 ]]; then
        vx_compose_error 'stored Compose definition is not a regular mode-0640 file'
    elif [[ ! -f "$metadata" || -L "$metadata" ]]; then
        vx_compose_error 'stored Compose metadata is invalid'
    elif ! profile="$(vx_compose_meta_get "$metadata" PROFILE)" \
        || ! vx_compose_profile_is_available "$profile"; then
        vx_compose_error 'stored Compose profile is invalid'
    elif ! revision="$(vx_compose_meta_get "$metadata" REVISION)" \
        || [[ ! "$revision" =~ ^[1-9][0-9]*$ ]]; then
        vx_compose_error 'stored Compose revision is invalid'
    elif ! export_root="$(mktemp -d \
        "${TMPDIR:-/tmp}/vx-compose-definition.XXXXXX")" \
        || ! chmod 0700 "$export_root"; then
        vx_compose_error 'Compose definition export temporary setup failed'
    else
        copy_file="$export_root/compose.yaml"
        candidate="$export_root/candidate"
        source_sha_before="$(sha256sum "$source_file" | awk '{print $1}')" \
            || source_sha_before=
        if [[ -z "$source_sha_before" ]] \
            || ! vx_compose_snapshot_source_file "$source_file" "$copy_file"; then
            vx_compose_error 'stored Compose definition copy failed'
        else
            expected_copy_uid="$(vx_compose_definition_export_expected_uid)" \
                || expected_copy_uid=
            if [[ ! "$expected_copy_uid" =~ ^[0-9]+$ ]]; then
                vx_compose_error \
                    'Compose definition export expected owner is invalid'
            elif [[ "$(stat -c '%u' "$copy_file" 2>/dev/null)" \
                    != "$expected_copy_uid" ]] \
                && ! chown "$expected_copy_uid" "$copy_file"; then
                vx_compose_error \
                    'Compose definition export copy ownership failed'
            elif ! chmod 0600 "$copy_file"; then
                vx_compose_error 'Compose definition export copy mode failed'
            else
                source_sha_after="$(
                    sha256sum "$source_file" | awk '{print $1}'
                )" || source_sha_after=
                copy_sha="$(sha256sum "$copy_file" | awk '{print $1}')" \
                    || copy_sha=
                if [[ "$(stat -c '%u' "$copy_file" 2>/dev/null)" \
                        != "$expected_copy_uid"
                    || "$(stat -c '%a' "$copy_file" 2>/dev/null)" != 600 ]]; then
                    vx_compose_error \
                        'Compose definition export copy ownership or mode is invalid'
                elif [[ -z "$source_sha_after" || -z "$copy_sha" ]] \
                    || ! [[ "$source_sha_before" == "$source_sha_after"
                        && "$source_sha_before" == "$copy_sha" ]] \
                    || ! cmp -s -- "$source_file" "$copy_file"; then
                    vx_compose_error \
                        'stored Compose definition changed during export'
                elif vx_compose_definition_contains_managed_secret \
                    "$root" "$copy_file"; then
                    vx_compose_error \
                        'stored Compose definition contains managed secret data'
                else
                    raw_candidate="$candidate-raw"
                    labeled_candidate="$candidate-labeled"
                    editable_candidate="$candidate-editable"
                    definition_file="$copy_file"
                    if vx_compose_prepare_candidate_quiet \
                        "$owner" "$project" "$copy_file" "$raw_candidate" \
                        "$profile"; then
                        :
                    elif vx_compose_prepare_candidate_quiet \
                        "$owner" "$project" "$copy_file" \
                        "$labeled_candidate" "$profile" yes \
                        && vx_compose_definition_write_editable \
                            "$labeled_candidate/canonical.json" \
                            "$export_root/editable.compose.json" \
                        && vx_compose_prepare_candidate_quiet \
                            "$owner" "$project" \
                            "$export_root/editable.compose.json" \
                            "$editable_candidate" "$profile"; then
                        definition_file="$export_root/editable.compose.json"
                    else
                        definition_file=
                        vx_compose_error \
                            'stored Compose definition fails current policy'
                    fi
                fi
                if [[ -n "$definition_file" ]]; then
                    definition_sha="$(sha256sum "$definition_file" \
                        | awk '{print $1}')" || definition_sha=
                    [[ "$definition_sha" =~ ^[a-f0-9]{64}$ ]] || {
                        vx_compose_error \
                            'stored Compose definition export digest failed'
                        definition_file=
                    }
                fi
                if [[ -n "$definition_file" ]]; then
                    jq -n -S --rawfile definition "$definition_file" \
                        --arg owner "$owner" \
                        --arg project "$project" \
                        --arg profile "$profile" \
                        --arg source_sha "$definition_sha" \
                        --argjson revision "$revision" '
                        {
                            OWNER: $owner,
                            PROJECT: $project,
                            PROFILE: $profile,
                            REVISION: $revision,
                            SOURCE_SHA256: $source_sha,
                            DEFINITION: $definition
                        }
                    ' && result=0
                fi
            fi
        fi
    fi

    [[ -z "$export_root" ]] || rm -rf -- "$export_root"
    vx_compose_lock_release
    return "$result"
}

vx_compose_candidate_deployment_plan_json() {
    local owner="$1"
    local project="$2"
    local profile="$3"
    local candidate="$4"
    local mode="$5"
    local source_sha="$6"
    local root current_json current_policy routes_file images_file snapshot_root
    local snapshot_ok
    local candidate_json candidate_policy candidate_sha current_revision=0
    local current='{"services":{},"networks":{},"volumes":{},"secrets":{}}'
    local routes='{}' current_identities='{}'
    local current_cpus=0 current_memory=0 current_pids=0 current_storage=0
    local candidate_cpus candidate_memory candidate_pids candidate_storage

    [[ "$mode" == add || "$mode" == change ]] || {
        vx_compose_error 'invalid Compose plan mode'
        return 1
    }
    [[ "$source_sha" =~ ^[a-f0-9]{64}$ ]] || {
        vx_compose_error 'invalid Compose source digest'
        return 1
    }
    candidate_json="$candidate/canonical.json"
    candidate_policy="$candidate/policy.conf"
    [[ -f "$candidate_json" && ! -L "$candidate_json"
        && -f "$candidate/canonical.sha256"
        && ! -L "$candidate/canonical.sha256"
        && -f "$candidate_policy" && ! -L "$candidate_policy" ]] || {
        vx_compose_error 'candidate Compose plan input is incomplete'
        return 1
    }
    candidate_sha="$(vx_compose_candidate_sha "$candidate")" || return 1
    [[ "$candidate_sha" =~ ^[a-f0-9]{64}$
        && "$(sha256sum "$candidate_json" | awk '{print $1}')" == "$candidate_sha" ]] \
        || {
            vx_compose_error 'candidate Compose digest does not match'
            return 1
        }
    jq -e 'type == "object" and (.services | type == "object")' \
        "$candidate_json" >/dev/null || {
        vx_compose_error 'candidate canonical JSON is invalid'
        return 1
    }
    candidate_cpus="$(vx_compose_policy_value \
        "$candidate_policy" CPUS_MILLI)" || return 1
    candidate_memory="$(vx_compose_policy_value \
        "$candidate_policy" MEMORY_MB)" || return 1
    candidate_pids="$(vx_compose_policy_value \
        "$candidate_policy" PIDS)" || return 1
    candidate_storage="$(vx_compose_policy_value \
        "$candidate_policy" STORAGE_MB)" || return 1

    if [[ "$mode" == change ]]; then
        vx_compose_require_project "$owner" "$project" || return 1
        root="$(vx_compose_project_root "$owner" "$project")"
        snapshot_root="$(mktemp -d \
            "${TMPDIR:-/tmp}/vx-compose-plan-current.XXXXXX")" || return 1
        chmod 0700 "$snapshot_root" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        snapshot_ok=no
        vx_compose_lock_acquire "$owner" "$project" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        if [[ -f "$root/project.conf" && ! -L "$root/project.conf"
            && -f "$root/runtime/canonical.json"
            && ! -L "$root/runtime/canonical.json"
            && -f "$root/policy.conf" && ! -L "$root/policy.conf" ]] \
            && cp --no-dereference -- \
                "$root/project.conf" "$snapshot_root/project.conf" \
            && cp --no-dereference -- \
                "$root/runtime/canonical.json" \
                "$snapshot_root/canonical.json" \
            && cp --no-dereference -- \
                "$root/policy.conf" "$snapshot_root/policy.conf"; then
            snapshot_ok=yes
            if [[ -e "$root/routes.conf" ]]; then
                if [[ -f "$root/routes.conf" && ! -L "$root/routes.conf" ]] \
                    && cp --no-dereference -- \
                        "$root/routes.conf" "$snapshot_root/routes.conf"; then
                    :
                else
                    snapshot_ok=no
                fi
            fi
            if [[ -e "$root/images.json" ]]; then
                if [[ -f "$root/images.json" && ! -L "$root/images.json" ]] \
                    && cp --no-dereference -- \
                        "$root/images.json" "$snapshot_root/images.json"; then
                    :
                else
                    snapshot_ok=no
                fi
            fi
        fi
        vx_compose_lock_release
        if [[ "$snapshot_ok" != yes ]]; then
            rm -rf -- "$snapshot_root"
            vx_compose_error 'current Compose plan snapshot failed'
            return 1
        fi
        current_json="$snapshot_root/canonical.json"
        current_policy="$snapshot_root/policy.conf"
        routes_file="$snapshot_root/routes.conf"
        images_file="$snapshot_root/images.json"
        current_revision="$(vx_compose_meta_get \
            "$snapshot_root/project.conf" REVISION)" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        [[ "$current_revision" =~ ^[1-9][0-9]*$ ]] || {
            rm -rf -- "$snapshot_root"
            vx_compose_error 'stored Compose revision is invalid'
            return 1
        }
        current="$(jq -c . "$current_json")" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        current_cpus="$(vx_compose_policy_value \
            "$current_policy" CPUS_MILLI)" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        current_memory="$(vx_compose_policy_value \
            "$current_policy" MEMORY_MB)" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        current_pids="$(vx_compose_policy_value \
            "$current_policy" PIDS)" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        current_storage="$(vx_compose_policy_value \
            "$current_policy" STORAGE_MB)" || {
            rm -rf -- "$snapshot_root"
            return 1
        }
        if [[ -f "$routes_file" && ! -L "$routes_file" ]]; then
            routes="$(jq -c . "$routes_file")" || {
                rm -rf -- "$snapshot_root"
                return 1
            }
        fi
        if [[ -f "$images_file" && ! -L "$images_file" ]]; then
            current_identities="$(jq -c . "$images_file")" || {
                rm -rf -- "$snapshot_root"
                return 1
            }
        fi
        rm -rf -- "$snapshot_root"
    fi

    jq -n -S \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg profile "$profile" \
        --arg mode "$mode" \
        --arg source_sha "$source_sha" \
        --arg candidate_sha "$candidate_sha" \
        --argjson revision "$current_revision" \
        --argjson current "$current" \
        --slurpfile candidate "$candidate_json" \
        --argjson routes "$routes" \
        --argjson identities "$current_identities" \
        --argjson current_cpus "$current_cpus" \
        --argjson current_memory "$current_memory" \
        --argjson current_pids "$current_pids" \
        --argjson current_storage "$current_storage" \
        --argjson candidate_cpus "$candidate_cpus" \
        --argjson candidate_memory "$candidate_memory" \
        --argjson candidate_pids "$candidate_pids" \
        --argjson candidate_storage "$candidate_storage" '
        def names($object): (($object // {}) | keys);
        def added($before; $after): names($after) - names($before);
        def removed($before; $after): names($before) - names($after);
        def changed($before; $after):
            [names($before)[] as $name
                | select(
                    ($after | has($name))
                    and $before[$name] != $after[$name]
                )
                | $name];
        def unchanged($before; $after):
            [names($before)[] as $name
                | select(
                    ($after | has($name))
                    and $before[$name] == $after[$name]
                )
                | $name];
        def published_port($service; $target):
            [
                $service.ports[]?
                | select(
                    (.target | tonumber) == ($target | tonumber)
                    and (.protocol // "tcp") == "tcp"
                    and (.host_ip // "") == "127.0.0.1"
                )
                | (.published | tonumber)
            ] | if length == 1 then .[0] else null end;
        ($candidate[0]) as $next
        | (added($current.services; $next.services)) as $services_added
        | (removed($current.services; $next.services)) as $services_removed
        | (changed($current.services; $next.services)) as $services_changed
        | (unchanged($current.services; $next.services)) as $services_unchanged
        | (
            $routes | to_entries | map(
                .value as $route
                | ($next.services[$route.SERVICE] // null) as $service
                | (if $service == null then null
                   else published_port($service; $route.CONTAINER_PORT)
                   end) as $next_port
                | {
                    domain: .key,
                    status: (
                        if $next_port == null then "INVALIDATED"
                        elif $next_port == ($route.HOST_PORT | tonumber)
                        then "UNCHANGED"
                        else "RETARGET_REQUIRED"
                        end
                    )
                }
            )
        ) as $route_results
        | {
            VALID: true,
            OWNER: $owner,
            PROJECT: $project,
            PROFILE: $profile,
            MODE: $mode,
            SOURCE_SHA256: $source_sha,
            CANDIDATE_SHA256: $candidate_sha,
            CURRENT_REVISION: $revision,
            SERVICES: {
                ADDED: $services_added,
                REMOVED: $services_removed,
                CHANGED: $services_changed,
                UNCHANGED: $services_unchanged
            },
            RECREATE_SERVICES: (($services_added + $services_changed) | unique),
            REMOVE_SERVICES: $services_removed,
            NETWORKS: {
                ADDED: added($current.networks; $next.networks),
                REMOVED: removed($current.networks; $next.networks),
                CHANGED: changed($current.networks; $next.networks),
                UNCHANGED: unchanged($current.networks; $next.networks)
            },
            VOLUMES: {
                ADDED: added($current.volumes; $next.volumes),
                REMOVED: removed($current.volumes; $next.volumes),
                CHANGED: changed($current.volumes; $next.volumes),
                UNCHANGED: unchanged($current.volumes; $next.volumes)
            },
            SECRETS: {
                ADDED: added($current.secrets; $next.secrets),
                REMOVED: removed($current.secrets; $next.secrets),
                CHANGED: changed($current.secrets; $next.secrets),
                UNCHANGED: unchanged($current.secrets; $next.secrets)
            },
            ROUTES: {
                UNCHANGED: [
                    $route_results[]
                    | select(.status == "UNCHANGED") | .domain
                ],
                INVALIDATED: [
                    $route_results[]
                    | select(.status == "INVALIDATED") | .domain
                ],
                RETARGET_REQUIRED: [
                    $route_results[]
                    | select(.status == "RETARGET_REQUIRED") | .domain
                ]
            },
            RESOURCES: {
                CURRENT: {
                    CPUS_MILLI: $current_cpus,
                    MEMORY_MB: $current_memory,
                    PIDS: $current_pids,
                    STORAGE_MB: $current_storage
                },
                CANDIDATE: {
                    CPUS_MILLI: $candidate_cpus,
                    MEMORY_MB: $candidate_memory,
                    PIDS: $candidate_pids,
                    STORAGE_MB: $candidate_storage
                },
                DELTA: {
                    CPUS_MILLI: ($candidate_cpus - $current_cpus),
                    MEMORY_MB: ($candidate_memory - $current_memory),
                    PIDS: ($candidate_pids - $current_pids),
                    STORAGE_MB: ($candidate_storage - $current_storage)
                }
            },
            IMAGES: {
                CURRENT_REFERENCES: (
                    [$current.services[]?.image // empty] | unique
                ),
                CANDIDATE_REFERENCES: (
                    [$next.services[]?.image // empty] | unique
                ),
                CURRENT_IDENTITIES: $identities
            },
            DATA_ROLLBACK: false,
            WARNINGS: (
                if (
                    [$next.services[]?.image // empty]
                    | any(
                        (contains("@sha256:") | not)
                        and (endswith(":local") | not)
                    )
                ) then [
                    "Image tags are resolved again at apply time; equal mutable tags do not guarantee equal image identities."
                ] else [] end
            )
        }'
}
