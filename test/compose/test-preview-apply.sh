#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/owner" "$VESTA/data/users/other" \
    "$HOMEDIR/owner" "$HOMEDIR/other"
printf "SUSPENDED='no'\n" >"$VESTA/data/users/owner/user.conf"
printf "SUSPENDED='no'\n" >"$VESTA/data/users/other/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(vx_compose_preview_expected_uid)" == 0
    && "$(vx_compose_preview_expected_gid)" == 0 ]] \
    || fail "production preview ownership defaults are not root:root"
test_uid="$(id -u)"
test_gid="$(id -g)"
vx_compose_preview_expected_uid() {
    printf '%s\n' "$test_uid"
}
vx_compose_preview_expected_gid() {
    printf '%s\n' "$test_gid"
}
vx_compose_preview_install() {
    command install -o "$test_uid" -g "$test_gid" "$@"
}
vx_compose_preview_set_ownership() {
    chown "$test_uid:$test_gid" "$@"
}

# Canonicalization is intentionally stubbed: this test isolates protected
# input handling, authority, and immutable preview storage.
vx_compose_prepare_candidate() {
    local owner="$1" project="$2"
    local output_root="$4"
    if [[ -n "${prepare_secret_sentinel:-}" ]]; then
        printf 'docker failure: %s at %s\n' \
            "$prepare_secret_sentinel" "$source_file" >&2
        return 1
    fi
    mkdir -m 0700 "$output_root"
    jq -n -S \
        --arg network "$(vx_compose_network_runtime_name \
            "$owner" "$project" default)" \
        --arg owner "$owner" --arg project "$project" '{
            services: {
                web: {
                    image: "example@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    networks: {default: null},
                    labels: {
                        "vx.managed": "yes",
                        "vx.user": $owner,
                        "vx.project": $project
                    }
                }
            },
            networks: {
                default: {
                    name: $network,
                    driver: "bridge",
                    labels: {
                        "vx.managed": "yes",
                        "vx.user": $owner,
                        "vx.project": $project,
                        "vx.network": "default"
                    }
                }
            },
            volumes: {},
            secrets: {}
        }' >"$output_root/canonical.json"
    install -m 0600 "$output_root/canonical.json" \
        "$output_root/compose.yaml"
    sha256sum "$output_root/canonical.json" \
        >"$output_root/canonical.sha256"
    printf "SERVICES='1'\nCPUS_MILLI='100'\nMEMORY_MB='64'\nPIDS='32'\nSTORAGE_MB='128'\n" \
        >"$output_root/policy.conf"
}

vx_compose_candidate_deployment_plan_json() {
    local owner="$1" project="$2" profile="$3" mode="$5" source_sha="$6"
    local candidate_sha
    candidate_sha="$(vx_compose_candidate_sha "$4")"
    jq -n -S --arg owner "$owner" --arg project "$project" \
        --arg profile "$profile" --arg mode "$mode" \
        --arg source_sha "$source_sha" --arg candidate_sha "$candidate_sha" '{
        VALID: true, OWNER: $owner, PROJECT: $project, PROFILE: $profile,
        MODE: $mode, SOURCE_SHA256: $source_sha,
        CANDIDATE_SHA256: $candidate_sha, CURRENT_REVISION: 0,
        SERVICES: {ADDED:["web"],REMOVED:[],CHANGED:[],UNCHANGED:[]},
        ROUTES:{UNCHANGED:[],INVALIDATED:[],RETARGET_REQUIRED:[]}
    }'
}

make_source() {
    local fault="${1:-}"
    local source_id
    renamed_source_parent=
    while :; do
        source_id="$(openssl rand -hex 16)"
        source_parent="/tmp/vx-compose-web.$source_id"
        if mkdir -m 0700 "$source_parent" 2>/dev/null; then
            break
        fi
    done
    source_file="$source_parent/compose.yaml"
    printf 'services:\n  web:\n    image: example:latest\n' >"$source_file"
    chmod 0600 "$source_file"
    case "$fault" in
        source_symlink)
            mv "$source_file" "$source_parent/real.yaml"
            ln -s real.yaml "$source_file"
            ;;
        parent_mode_0755) chmod 0755 "$source_parent" ;;
        source_mode_0644) chmod 0644 "$source_file" ;;
        source_too_old) touch -d '20 minutes ago' "$source_file" ;;
    esac
}

discard_test_source() {
    rm -f -- "$source_file" "$source_parent/real.yaml" \
        "$source_parent/original" "$source_parent/replacement"
    rmdir -- "$source_parent" 2>/dev/null || :
    if [[ -n "${renamed_source_parent:-}" ]]; then
        rm -f -- "$renamed_source_parent/compose.yaml"
        rmdir -- "$renamed_source_parent"
    fi
}

stage_success() {
    local actor="$1" owner="$2" profile="$3"
    local output preview_id preview_root source_sha candidate_sha saved_source
    make_source
    output="$(vx_compose_preview_stage \
        "$actor" "$owner" project "$source_file" "$profile" add)" \
        || fail "stage_success $actor $owner $profile"
    preview_id="$(jq -r .PREVIEW_ID <<<"$output")"
    source_sha="$(jq -r .SOURCE_SHA256 <<<"$output")"
    candidate_sha="$(jq -r .CANDIDATE_SHA256 <<<"$output")"
    vx_compose_preview_id_is_valid "$preview_id" \
        || fail "invalid preview ID"
    preview_root="$VESTA/data/tmp/compose-previews/$preview_id"
    [[ "$(stat -c '%u:%g:%a' "$preview_root")" \
        == "$test_uid:$test_gid:700" ]] \
        || fail "preview directory protection is wrong"
    find "$preview_root" -mindepth 1 -maxdepth 1 \
        -exec test ! -L {} \; -exec test -f {} \; \
        || fail "preview contains a link or non-file"
    [[ "$(sha256sum "$preview_root/source.compose.yaml" | awk '{print $1}')" \
        == "$source_sha" ]] || fail "staged source hash mismatch"
    [[ "$(sha256sum "$preview_root/canonical.json" | awk '{print $1}')" \
        == "$candidate_sha" ]] || fail "candidate hash mismatch"
    [[ ! -e "$source_parent" ]] || fail "trusted source parent was retained"

    jq -e '.services.web.labels == {
        "vx.managed": "yes", "vx.user": "owner", "vx.project": "project"
    }' "$preview_root/compose.yaml" >/dev/null \
        || fail "generated candidate ownership labels are missing"
    saved_source="$(sha256sum "$preview_root/source.compose.yaml")"
    mkdir -m 0700 "$source_parent"
    printf 'changed\n' >"$source_file"
    discard_test_source
    [[ "$(sha256sum "$preview_root/source.compose.yaml")" == "$saved_source" ]] \
        || fail "preview changed with original source"
    [[ "$(jq -r .SOURCE_SHA256 <<<"$output")" == "$source_sha"
        && "$(jq -r .CANDIDATE_SHA256 <<<"$output")" == "$candidate_sha" ]] \
        || fail "returned preview digests changed"
}

stage_failure() {
    local actor="$1" owner="$2" profile="$3" fault="${4:-}"
    local trusted=no stage_diagnostics
    make_source "$fault"
    if [[ "$fault" == source_parent_swap_during_copy ]]; then
        renamed_source_parent="${source_parent}.renamed"
    fi
    [[ -z "$fault" || "$fault" == source_swap_during_copy ]] && trusted=yes
    if [[ "$fault" == source_swap_during_copy \
        || "$fault" == source_inode_swap_during_copy \
        || "$fault" == source_symlink_swap_during_copy \
        || "$fault" == source_parent_swap_during_copy ]]; then
        cp() {
            command cp "$@"
            if [[ "$*" == *"$source_file"* && "$*" == *"/compose.yaml"* ]]; then
                case "$fault" in
                    source_swap_during_copy)
                        printf 'swapped\n' >"$source_file"
                        ;;
                    source_inode_swap_during_copy)
                        printf 'services:\n  web:\n    image: example:latest\n' \
                            >"$source_parent/replacement"
                        chmod 0600 "$source_parent/replacement"
                        mv -f "$source_parent/replacement" "$source_file"
                        ;;
                    source_symlink_swap_during_copy)
                        mv "$source_file" "$source_parent/original"
                        ln -s original "$source_file"
                        ;;
                    source_parent_swap_during_copy)
                        renamed_source_parent="${source_parent}.renamed"
                        mv "$source_parent" "$renamed_source_parent"
                        mkdir -m 0700 "$source_parent"
                        printf 'replacement must be retained\n' >"$source_file"
                        chmod 0600 "$source_file"
                        ;;
                esac
            fi
        }
    fi
    if stage_diagnostics="$(vx_compose_preview_stage \
        "$actor" "$owner" project "$source_file" "$profile" add \
        2>&1)"; then
        fail "stage_failure $actor $owner $profile $fault"
    fi
    unset -f cp 2>/dev/null || :
    if [[ "$fault" == source_swap_during_copy \
        || "$fault" == source_inode_swap_during_copy \
        || "$fault" == source_symlink_swap_during_copy \
        || "$fault" == source_parent_swap_during_copy ]]; then
        [[ -e "$source_parent" ]] \
            || fail "replaced trusted source parent was removed"
        [[ "$stage_diagnostics" \
            == *'trusted web source identity changed; cleanup retained'* ]] \
            || fail "replaced trusted source did not return fixed cleanup error"
        [[ "$stage_diagnostics" != *"$source_file"*
            && "$stage_diagnostics" != *'replacement must be retained'* ]] \
            || fail "trusted cleanup diagnostic exposed a path or content"
        if [[ "$fault" == source_parent_swap_during_copy ]]; then
            [[ -f "$source_file"
                && -f "$renamed_source_parent/compose.yaml" ]] \
                || fail "parent replacement race removed trusted or replacement data"
        fi
        discard_test_source
    elif [[ -n "$fault" ]]; then
        [[ -e "$source_parent" ]] \
            || fail "untrusted failed source was removed"
        discard_test_source
        [[ ! -e "$source_parent" ]] \
            || fail "PHP-style exact discard failed"
    elif [[ "$trusted" == yes ]]; then
        # Authority failures occur before the protected path is trusted.
        [[ -e "$source_parent" ]] || fail "unauthorized source was removed"
        discard_test_source
    fi
}

stage_success owner owner standard
stage_success admin owner standard
stage_failure owner other standard
stage_failure owner owner admin-approved
stage_failure admin owner admin-approved
stage_failure owner owner standard source_symlink
stage_failure owner owner standard parent_mode_0755
stage_failure owner owner standard source_mode_0644
stage_failure owner owner standard source_too_old
stage_failure owner owner standard source_swap_during_copy
stage_failure owner owner standard source_inode_swap_during_copy
stage_failure owner owner standard source_symlink_swap_during_copy
stage_failure owner owner standard source_parent_swap_during_copy

make_source
prepare_secret_sentinel='SECRET-SENTINEL-MUST-NOT-LEAK'
{ set +x; } 2>/dev/null
if prepare_diagnostics="$(vx_compose_preview_stage \
    owner owner project "$source_file" standard add 2>&1)"; then
    fail "candidate diagnostic failure unexpectedly staged"
fi
unset prepare_secret_sentinel
[[ "$prepare_diagnostics" == *'Compose candidate preparation failed'* ]] \
    || fail "candidate failure did not return the fixed diagnostic"
[[ "$prepare_diagnostics" != *'SECRET-SENTINEL-MUST-NOT-LEAK'*
    && "$prepare_diagnostics" != *"$source_file"* ]] \
    || fail "candidate diagnostics leaked protected content or path"
[[ ! -e "$source_parent" ]] \
    || fail "candidate failure retained already-consumed web source"

base_preview="$(find "$VESTA/data/tmp/compose-previews" -mindepth 1 \
    -maxdepth 1 -type d -print -quit)"
[[ -n "$base_preview" ]] || fail "no preview fixture available for GC tests"

clone_preview() {
    local id="$1"
    target_preview="$VESTA/data/tmp/compose-previews/$id"
    cp -a -- "$base_preview" "$target_preview"
}

malformed="$VESTA/data/tmp/compose-previews/short"
mkdir "$malformed"
vx_compose_preview_gc 2>/dev/null
[[ -d "$malformed" ]] || fail "GC removed malformed-length entry"

preview_root_parent="$VESTA/data/tmp/compose-previews"
chmod 0755 "$preview_root_parent"
if vx_compose_preview_gc >/dev/null 2>&1; then
    fail "GC accepted a wrong-mode preview root"
fi
[[ -d "$preview_root_parent" ]] || fail "GC removed a wrong-mode preview root"
chmod 0700 "$preview_root_parent"

saved_uid="$test_uid"
saved_gid="$test_gid"
test_uid=$((saved_uid + 1))
test_gid=$((saved_gid + 1))
if vx_compose_preview_gc >/dev/null 2>&1; then
    fail "GC accepted a wrong-owner preview root"
fi
[[ -d "$preview_root_parent" ]] || fail "GC removed a wrong-owner preview root"
test_uid="$saved_uid"
test_gid="$saved_gid"

linked="$VESTA/data/tmp/compose-previews/11111111111111111111111111111111"
ln -s "$base_preview" "$linked"
vx_compose_preview_gc 2>/dev/null
[[ -L "$linked" ]] || fail "GC removed linked entry"

clone_preview 22222222222222222222222222222222
chmod 0755 "$target_preview"
vx_compose_preview_gc 2>/dev/null
[[ -d "$target_preview" ]] || fail "GC removed wrong-mode preview"

clone_preview 44444444444444444444444444444444
printf "UNKNOWN='value'\n" >>"$target_preview/preview.conf"
vx_compose_preview_gc 2>/dev/null
[[ -d "$target_preview" ]] || fail "GC removed unknown-metadata preview"

clone_preview 55555555555555555555555555555555
printf "EXPIRES_EPOCH='1'\n" >>"$target_preview/preview.conf"
vx_compose_preview_gc 2>/dev/null
[[ -d "$target_preview" ]] || fail "GC removed duplicate-expiry preview"

clone_preview 66666666666666666666666666666666
vx_compose_preview_gc 2>/dev/null
[[ -d "$target_preview" ]] || fail "GC removed valid unexpired preview"

clone_preview 77777777777777777777777777777777
sed -i \
    -e "s/^CREATED_EPOCH=.*/CREATED_EPOCH='1'/" \
    -e "s/^EXPIRES_EPOCH=.*/EXPIRES_EPOCH='901'/" \
    "$target_preview/preview.conf"
vx_compose_preview_gc 2>/dev/null
[[ ! -e "$target_preview" ]] || fail "GC retained valid expired preview"
[[ -d "$VESTA/data/tmp/compose-previews" ]] \
    || fail "GC targeted the preview root"

echo "Compose immutable preview staging tests passed."

# Exact apply matrix. Runtime convergence is isolated behind scoped stubs while
# the real preview verifier, project flock, actor context, consume/quarantine,
# and apply orchestration execute against realistic protected project files.
apply_project_root="$VESTA/data/users/owner/docker-projects/project"
docker_calls="$test_root/docker.calls"
: >"$docker_calls"
mkdir -p "$HOMEDIR/owner/docker/project/data"
printf 'retained\n' >"$HOMEDIR/owner/docker/project/data/canary"

reset_apply_project() {
    rm -rf -- "$apply_project_root"
    mkdir -p "$apply_project_root/runtime"
    printf "OWNER='owner'\nPROJECT='project'\nPROFILE='standard'\nSTATE='running'\nREVISION='1'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='prior'\n" \
        >"$apply_project_root/project.conf"
    printf 'services: {web: {image: prior}}\n' \
        >"$apply_project_root/compose.yaml"
    printf '{"services":{"web":{"image":"prior"}}}\n' \
        >"$apply_project_root/runtime/canonical.json"
    printf "SERVICES='1'\n" >"$apply_project_root/policy.conf"
    printf '{"route":"prior"}\n' >"$apply_project_root/routes.conf"
}

make_apply_preview() {
    local id="$1" actor="$2" mode="${3:-change}" revision="${4:-1}"
    local now
    target_preview="$VESTA/data/tmp/compose-previews/$id"
    cp -a -- "$base_preview" "$target_preview"
    now="$(date +%s)"
    sed -i \
        -e "s/^ACTOR=.*/ACTOR='$actor'/" \
        -e "s/^MODE=.*/MODE='$mode'/" \
        -e "s/^EXPECTED_CURRENT_REVISION=.*/EXPECTED_CURRENT_REVISION='$revision'/" \
        -e "s/^CREATED_EPOCH=.*/CREATED_EPOCH='$now'/" \
        -e "s/^EXPIRES_EPOCH=.*/EXPIRES_EPOCH='$((now + 900))'/" \
        "$target_preview/preview.conf"
    apply_source_sha="$(vx_compose_meta_get \
        "$target_preview/preview.conf" SOURCE_SHA256)"
    apply_candidate_sha="$(vx_compose_meta_get \
        "$target_preview/preview.conf" CANDIDATE_SHA256)"
}

apply_state() {
    local revision compose canonical route calls
    revision="$(vx_compose_meta_get "$apply_project_root/project.conf" REVISION)"
    compose="$(sha256sum "$apply_project_root/compose.yaml" \
        | awk '{print $1}')"
    canonical="$(sha256sum "$apply_project_root/runtime/canonical.json" \
        | awk '{print $1}')"
    route="$(sha256sum "$apply_project_root/routes.conf" | awk '{print $1}')"
    calls="$(wc -l <"$docker_calls")"
    printf '%s:%s:%s:%s:%s\n' \
        "$revision" "$compose" "$canonical" "$route" "$calls"
}

deploy_result=success
deploy_barrier=
vx_compose_transaction_update() {
    local owner="$1" project="$2" candidate="$3" expected="$4"
    local root prior_revision prior_compose prior_canonical prior_route
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ "$(jq -r '.networks.default.name' "$candidate/canonical.json")" \
        == "$(vx_compose_runtime_name "$owner" "$project")_default" ]] \
        || return 1
    [[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == "$expected" ]] \
        || return 1
    prior_revision="$expected"
    prior_compose="$(cat "$root/compose.yaml")"
    prior_canonical="$(cat "$root/runtime/canonical.json")"
    prior_route="$(cat "$root/routes.conf")"
    printf 'compose up vx-%s-%s\n' "$owner" "$project" >>"$docker_calls"
    if [[ -n "$deploy_barrier" ]]; then
        printf 'ready\n' >>"$test_root/deploy.ready"
        IFS= read -r _ <"$deploy_barrier"
    fi
    sed -i "s/^REVISION='$expected'/REVISION='$((expected + 1))'/" \
        "$root/project.conf"
    install -m 0640 "$candidate/compose.yaml" "$root/compose.yaml"
    install -m 0640 "$candidate/canonical.json" \
        "$root/runtime/canonical.json"
    printf '{"route":"candidate"}\n' >"$root/routes.conf"
    if [[ "$deploy_result" == unhealthy ]]; then
        printf '%s\n' "$prior_compose" >"$root/compose.yaml"
        printf '%s\n' "$prior_canonical" >"$root/runtime/canonical.json"
        printf '%s\n' "$prior_route" >"$root/routes.conf"
        sed -i "s/^REVISION='$((expected + 1))'/REVISION='$prior_revision'/" \
            "$root/project.conf"
        vx_compose_audit "$root" transaction-update failed \
            'candidate convergence failed; rolling back'
        return 1
    fi
    vx_compose_audit "$root" transaction-update succeeded
}
vx_compose_store_new() {
    local owner="$1" project="$2" candidate="$4" root
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ ! -e "$root" ]] || return 1
    mkdir -p "$root/runtime"
    install -m 0640 "$candidate/compose.yaml" "$root/compose.yaml"
    install -m 0640 "$candidate/canonical.json" "$root/runtime/canonical.json"
    install -m 0640 "$candidate/policy.conf" "$root/policy.conf"
    printf '{}\n' >"$root/routes.conf"
    printf "OWNER='%s'\nPROJECT='%s'\nPROFILE='standard'\nSTATE='validated'\nREVISION='1'\nCREATED='now'\nCANONICAL_SHA256='%s'\n" \
        "$owner" "$project" "$(vx_compose_candidate_sha "$candidate")" \
        >"$root/project.conf"
    vx_compose_audit "$root" create succeeded
}
vx_compose_deploy() {
    printf 'compose up vx-%s-%s\n' "$1" "$2" >>"$docker_calls"
    [[ "$deploy_result" == success ]]
}
vx_compose_remove() {
    printf 'compose down vx-%s-%s\n' "$1" "$2" >>"$docker_calls"
    vx_compose_remove_control_root "$1" "$2"
    vx_compose_refresh_counters "$1"
}
vx_compose_refresh_counters() {
    printf 'refreshed:%s\n' "$1" >>"$test_root/counters"
}

apply_success() {
    local actor="$1" id="$2" audit
    reset_apply_project
    make_apply_preview "$id" "$actor"
    vx_compose_preview_apply "$actor" owner project "$id" \
        "$apply_source_sha" "$apply_candidate_sha" 1 \
        || fail "apply success failed for $actor"
    [[ ! -e "$target_preview" ]] || fail "successful preview was not consumed"
    audit="$(tail -1 "$apply_project_root/audit.log")"
    jq -e --arg actor "$actor" \
        '.ACTOR == $actor and .OWNER == "owner"' <<<"$audit" >/dev/null \
        || fail "apply audit actor/owner attribution is wrong for $actor"
    jq -e '.services.web.labels == {
        "vx.managed": "yes", "vx.user": "owner", "vx.project": "project"
    }' "$apply_project_root/compose.yaml" >/dev/null \
        || fail "apply persisted the submitted source instead of the candidate"
    [[ -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]] \
        || fail "successful apply leaked private actor context"
}
apply_success owner aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1
apply_success admin aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2

rm -rf -- "$apply_project_root"
make_apply_preview aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3 owner add 0
vx_compose_preview_apply owner owner project \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3 "$apply_source_sha" \
    "$apply_candidate_sha" 0 || fail "add apply success failed"
jq -e '.services.web.labels == {
    "vx.managed": "yes", "vx.user": "owner", "vx.project": "project"
}' "$apply_project_root/compose.yaml" >/dev/null \
    || fail "add apply persisted the submitted source instead of the candidate"
[[ ! -e "$target_preview" ]] || fail "successful add preview was not consumed"

apply_failure() {
    local case_name="$1" id="$2" before after invoke_actor=owner invoke_owner=owner
    reset_apply_project
    make_apply_preview "$id" owner
    case "$case_name" in
        wrong_actor) invoke_actor='admin' ;;
        wrong_owner) invoke_actor='other'; invoke_owner='other' ;;
        wrong_profile)
            sed -i "s/^PROFILE=.*/PROFILE='admin-approved'/" \
                "$target_preview/preview.conf"
            ;;
        expired)
            sed -i -e "s/^CREATED_EPOCH=.*/CREATED_EPOCH='1'/" \
                -e "s/^EXPIRES_EPOCH=.*/EXPIRES_EPOCH='901'/" \
                "$target_preview/preview.conf"
            ;;
        source_swap) printf 'swapped\n' >"$target_preview/source.compose.yaml" ;;
        compose_swap) printf 'swapped\n' >"$target_preview/compose.yaml" ;;
        canonical_swap) printf '{}\n' >"$target_preview/canonical.json" ;;
        source_digest_mismatch) apply_source_sha="$(printf x | sha256sum | awk '{print $1}')" ;;
        candidate_digest_mismatch) apply_candidate_sha="$(printf x | sha256sum | awk '{print $1}')" ;;
        expected_revision_mismatch) expected_arg=2 ;;
    esac
    before="$(apply_state)"
    expected_arg="${expected_arg:-1}"
    if vx_compose_preview_apply "$invoke_actor" "$invoke_owner" project "$id" \
        "$apply_source_sha" "$apply_candidate_sha" "$expected_arg"; then
        fail "apply refusal unexpectedly succeeded: $case_name"
    fi
    after="$(apply_state)"
    [[ "$before" == "$after" ]] \
        || fail "apply refusal mutated state or Docker: $case_name"
    [[ -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]] \
        || fail "failed apply leaked private actor context: $case_name"
    case "$case_name" in
        wrong_profile|source_swap|compose_swap|canonical_swap)
            compgen -G \
                "$VESTA/data/tmp/compose-previews/.rejected-$id-*" \
                >/dev/null || fail "tampered preview was not quarantined: $case_name"
            ;;
        *) [[ -e "$target_preview" ]] \
            || fail "non-tamper refusal consumed preview: $case_name" ;;
    esac
    unset expected_arg
}
apply_failure wrong_actor bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1
apply_failure wrong_owner bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2
apply_failure wrong_profile bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb3
apply_failure expired bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb4

reset_apply_project
linked_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb5
ln -s "$base_preview" "$VESTA/data/tmp/compose-previews/$linked_id"
before="$(apply_state)"
if vx_compose_preview_apply owner owner project "$linked_id" \
    "$(vx_compose_meta_get "$base_preview/preview.conf" SOURCE_SHA256)" \
    "$(vx_compose_meta_get "$base_preview/preview.conf" CANDIDATE_SHA256)" 1; then
    fail 'preview symlink apply unexpectedly succeeded'
fi
[[ "$before" == "$(apply_state)" ]] || fail 'preview symlink mutated state'

apply_failure compose_swap bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb6
apply_failure canonical_swap bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb7
apply_failure source_digest_mismatch bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb8
apply_failure candidate_digest_mismatch bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb9
apply_failure expected_revision_mismatch bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb10
apply_failure source_swap bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb11

# Already-consumed is a refusal against the state produced by the first apply.
reset_apply_project
make_apply_preview ccccccccccccccccccccccccccccccc1 owner
vx_compose_preview_apply owner owner project \
    ccccccccccccccccccccccccccccccc1 "$apply_source_sha" \
    "$apply_candidate_sha" 1 || fail 'initial consume failed'
before="$(apply_state)"
if vx_compose_preview_apply owner owner project \
    ccccccccccccccccccccccccccccccc1 "$apply_source_sha" \
    "$apply_candidate_sha" 1; then
    fail 'already consumed preview applied twice'
fi
[[ "$before" == "$(apply_state)" ]] || fail 'already consumed refusal mutated state'

# Simultaneous applies share one FIFO-held convergence. Exactly one process
# wins and consumes; the second observes stale/consumed state after the lock.
reset_apply_project
make_apply_preview ccccccccccccccccccccccccccccccc2 owner
deploy_barrier="$test_root/apply.fifo"
mkfifo "$deploy_barrier"
: >"$test_root/deploy.ready"
run_apply() {
    local name="$1" status=0
    vx_compose_preview_apply owner owner project \
        ccccccccccccccccccccccccccccccc2 "$apply_source_sha" \
        "$apply_candidate_sha" 1 || status=$?
    printf '%s:%s\n' "$name" "$status" >"$test_root/$name.apply"
}
run_apply first &
first_apply_pid=$!
run_apply second &
second_apply_pid=$!
for _ in {1..100}; do
    [[ -s "$test_root/deploy.ready" ]] && break
    sleep 0.02
done
printf 'release\n' >"$deploy_barrier"
wait "$first_apply_pid" "$second_apply_pid"
apply_statuses="$(cat "$test_root/first.apply" "$test_root/second.apply")"
[[ "$(grep -c ':0$' <<<"$apply_statuses")" == 1
    && "$(grep -cv ':0$' <<<"$apply_statuses")" == 1 ]] \
    || fail 'simultaneous preview apply did not produce one winner'
deploy_barrier=

# Unhealthy convergence restores exact prior revision/canonical/routes,
# retains the preview, and writes a failed owner-attributed audit event.
reset_apply_project
make_apply_preview ccccccccccccccccccccccccccccccc3 owner
before="$(apply_state)"
deploy_result=unhealthy
if vx_compose_preview_apply owner owner project \
    ccccccccccccccccccccccccccccccc3 "$apply_source_sha" \
    "$apply_candidate_sha" 1; then
    fail 'unhealthy candidate unexpectedly succeeded'
fi
deploy_result=success
after="$(apply_state)"
[[ "${before%:*}" == "${after%:*}"
    && "$(( ${after##*:} - ${before##*:} ))" == 1 ]] \
    || fail 'unhealthy rollback did not preserve prior state'
[[ -d "$target_preview" ]] || fail 'convergence failure consumed preview'
jq -e 'select(.ACTION == "transaction-update" and .RESULT == "failed")
    | .ACTOR == "owner" and .OWNER == "owner"' \
    "$apply_project_root/audit.log" >/dev/null \
    || fail 'unhealthy rollback audit is missing'

# Add-mode convergence cleanup is scoped, retains owner data, refreshes
# counters, and never emits a prune command.
rm -rf -- "$apply_project_root"
make_apply_preview ccccccccccccccccccccccccccccccc4 owner add 0
deploy_result=unhealthy
if vx_compose_preview_apply owner owner project \
    ccccccccccccccccccccccccccccccc4 "$apply_source_sha" \
    "$apply_candidate_sha" 0; then
    fail 'unhealthy add unexpectedly succeeded'
fi
deploy_result=success
[[ ! -e "$apply_project_root"
    && -f "$HOMEDIR/owner/docker/project/data/canary"
    && -d "$target_preview" ]] || fail 'add cleanup removed data or preview'
grep -Fq 'compose down vx-owner-project' "$docker_calls" \
    || fail 'add cleanup did not target the scoped runtime'
! grep -qi prune "$docker_calls" || fail 'add cleanup invoked prune'
grep -Fq 'refreshed:owner' "$test_root/counters" \
    || fail 'add cleanup did not refresh counters'
jq -e 'select(.ACTION == "preview-apply" and .RESULT == "failed")
    | .ACTOR == "owner" and .OWNER == "owner"' \
    "$VESTA/data/users/owner/docker-audit.log" >/dev/null \
    || fail 'add convergence cleanup did not retain its failure audit'

# If any scoped teardown stage fails, identity and candidate evidence remain
# retryable; control metadata must not be deleted around possibly-live runtime.
vx_compose_remove() {
    printf '%s-failed vx-%s-%s\n' "$teardown_fault" "$1" "$2" \
        >>"$docker_calls"
    printf '%s-may-remain\n' "$teardown_fault" \
        >"$(vx_compose_project_root "$1" "$2")/runtime/cleanup.evidence"
    return 1
}
for teardown_case in \
    down:ccccccccccccccccccccccccccccccc5 \
    route:ccccccccccccccccccccccccccccccc6 \
    profile:ccccccccccccccccccccccccccccccc7
do
    teardown_fault="${teardown_case%%:*}"
    teardown_id="${teardown_case#*:}"
    rm -rf -- "$apply_project_root"
    make_apply_preview "$teardown_id" owner add 0
    deploy_result=unhealthy
    if vx_compose_preview_apply owner owner project \
        "$teardown_id" "$apply_source_sha" "$apply_candidate_sha" 0; then
        fail "$teardown_fault failed-teardown add unexpectedly succeeded"
    fi
    deploy_result=success
    [[ -d "$apply_project_root"
        && -f "$apply_project_root/runtime/cleanup.evidence"
        && -f "$apply_project_root/compose.yaml"
        && -f "$HOMEDIR/owner/docker/project/data/canary"
        && "$(vx_compose_meta_get "$apply_project_root/project.conf" STATE)" \
            == cleanup-required
        && -d "$target_preview" ]] \
        || fail "$teardown_fault teardown lost retryable control/runtime evidence"
    jq -e 'select(.ACTION == "preview-cleanup" and .RESULT == "failed")
        | .ACTOR == "owner" and .OWNER == "owner"
        and (.DETAILS | contains("control metadata retained"))' \
        "$apply_project_root/audit.log" >/dev/null \
        || fail "$teardown_fault teardown cleanup audit is missing"
done
! grep -qi prune "$docker_calls" || fail 'failed teardown invoked prune'

echo "Compose exact preview apply matrix passed."
