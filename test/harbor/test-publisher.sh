#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }
_vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid(){ id -g; }
_vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare

identity="$HARBOR_TEST_ROOT/publisher.agekey"
age-keygen -o "$identity" >/dev/null 2>&1
recipient="$(age-keygen -y "$identity")"
create_count="$HARBOR_TEST_ROOT/create"; robots_file="$HARBOR_TEST_ROOT/robots.json"; delete_log="$HARBOR_TEST_ROOT/delete"
printf 0 >"$create_count"; printf '[]\n' >"$robots_file"; : >"$delete_log"

_vx_harbor_api_project_robot_create_secret_once(){
    local project="$1" namespace="$2" basename="$3" marker="$4" access="$5" value id name secret temporary
    [[ "$project" == 1 && "$namespace" == vx-* && "$basename" == publisher-* && "$access" == push-pull ]]
    [[ "$marker" == "vesta-managed:vesta-harbor:${namespace#vx-}:publisher:${basename#publisher-}" ]]
    value="$(<"$create_count")"; value=$((value+1)); printf '%s\n' "$value" >"$create_count"
    id=$((40+value)); name="robot\$$namespace+$basename"; secret="publisher-generated-$id-0123456789abcdef"
    temporary="$robots_file.tmp"
    jq --argjson id "$id" --arg name "$name" --arg marker "$marker" --arg namespace "$namespace" \
      '.+[{id:$id,name:$name,description:$marker,level:"project",permissions:[{kind:"project",namespace:$namespace,access:[{resource:"repository",action:"pull"},{resource:"repository",action:"push"}]}]}]' "$robots_file" >"$temporary"
    mv "$temporary" "$robots_file"
    jq -cn --arg name "$name" --arg secret "$secret" --argjson id "$id" \
      '{creation_time:"2026-08-09T00:00:00Z",expires_at:-1,id:$id,name:$name,secret:$secret}'
}
vx_harbor_api_credential_probe(){ local username="$1" value; value="$(cat)"; [[ "$username" == robot\$* && "$value" == publisher-generated-*-0123456789abcdef ]]; }
vx_harbor_api_project_robots_list(){ cat "$robots_file"; }
vx_harbor_api_project_robot_find(){
    local project="$1" marker="$2" value
    value="$(jq -c --arg marker "$marker" '[.[]|select(.description==$marker)]' "$robots_file")"
    [[ "$(jq -r length <<<"$value")" == 1 ]] || return 4
    jq -c '.[0]' <<<"$value"
}
vx_harbor_api_project_robot_delete(){
    local project="$1" id="$2" marker="$3" temporary
    [[ "$id" != "${delete_outage_id:-}" ]] || return 75
    # The real adapter treats an already absent marker as successful deletion.
    jq -e --arg marker "$marker" '.[]|select(.description==$marker)' "$robots_file" >/dev/null || return 0
    jq -e --argjson id "$id" --arg marker "$marker" '.[]|select(.id==$id and .description==$marker)' "$robots_file" >/dev/null || return 1
    printf '%s\t%s\n' "$id" "$marker" >>"$delete_log"
    temporary="$robots_file.tmp"; jq --argjson id "$id" '[.[]|select(.id!=$id)]' "$robots_file" >"$temporary"; mv "$temporary" "$robots_file"
}
prepare_owner(){
    local owner="$1" now path source_file
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; path="$(vx_harbor_owner_state_path "$owner")"
    source_file="$(mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")"
    jq -n --arg owner "$owner" --arg ns "vx-$owner" --arg now "$now" \
      '{SCHEMA:1,OWNER:$owner,NAMESPACE:$ns,PROJECT_ID:1,QUOTA_ID:1,QUOTA_MB:100,
        STATE:"runtime-ready",RUNTIME_ROBOT_ID:10,RUNTIME_USERNAME:"runtime",
        PUBLISHER_ROBOT_ID:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,
        LAST_ERROR:null,UPDATED_AT:$now}' >"$source_file"
    vx_harbor_json_write_atomic "$path" "$source_file"; rm -f "$source_file"
}

prepare_owner alice
! printf short | vx_harbor_publisher_rotate_locked alice >/dev/null
[[ "$(<"$create_count")" == 0 ]]

ciphertext="$(printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice)"
[[ "$ciphertext" == '-----BEGIN AGE ENCRYPTED FILE-----'* ]]
plaintext="$(printf '%s\n' "$ciphertext" | age -d -i "$identity")"
[[ "$plaintext" == publisher-generated-41-0123456789abcdef ]]
owner_path="$(vx_harbor_owner_state_path alice)"; journal="$(vx_harbor_rotation_path alice publisher)"
jq -e '.PUBLISHER_ROBOT_ID==41 and .PUBLISHER_ENABLED==true' "$owner_path" >/dev/null
jq -e '.OPERATION_ID as $operation | .SCHEMA==2 and .PHASE=="converged" and .PROJECT_ID==1 and (.DESCRIPTION|endswith($operation)) and (has("secret")|not)' "$journal" >/dev/null
[[ "$(jq -r length "$robots_file")" == 1 ]]

# The next rotation replaces the first robot and returns only the new envelope.
ciphertext="$(printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice)"
plaintext="$(printf '%s\n' "$ciphertext" | age -d -i "$identity")"
[[ "$plaintext" == publisher-generated-42-0123456789abcdef ]]
jq -e '.PUBLISHER_ROBOT_ID==42 and .PUBLISHER_ENABLED==true' "$owner_path" >/dev/null
[[ "$(jq -r '.[0].id' "$robots_file")" == 42 && "$(cut -f1 "$delete_log")" == 41 ]]

# A crash after authority switch is recovered by replacing the inaccessible
# generation on the next explicit rotation.
crash_point=authority-switched
_vx_harbor_rotation_checkpoint(){ [[ "$1:$2" != "publisher:$crash_point" ]]; }
! printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice >"$HARBOR_TEST_ROOT/failed-output"
[[ ! -s "$HARBOR_TEST_ROOT/failed-output" ]]
jq -e '.PUBLISHER_ROBOT_ID==43' "$owner_path" >/dev/null
crash_point=none
ciphertext="$(printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice)"
plaintext="$(printf '%s\n' "$ciphertext" | age -d -i "$identity")"
[[ "$plaintext" == publisher-generated-44-0123456789abcdef ]]
jq -e '.PUBLISHER_ROBOT_ID==44' "$owner_path" >/dev/null
[[ "$(jq -r length "$robots_file")" == 1 && "$(jq -r '.[0].id' "$robots_file")" == 44 ]]

for secret in publisher-generated-41-0123456789abcdef publisher-generated-42-0123456789abcdef publisher-generated-43-0123456789abcdef publisher-generated-44-0123456789abcdef; do
    ! grep -RFq "$secret" "$(vx_harbor_root)" "$delete_log" || fail 'publisher plaintext entered durable state or audit'
done

assert_disabled(){
    jq -e '.PUBLISHER_ENABLED==false and .PUBLISHER_ROBOT_ID==null and .PUBLISHER_USERNAME==null
      and .STATE=="publisher-disabled" and .RUNTIME_ROBOT_ID==10 and .RUNTIME_USERNAME=="runtime"' "$owner_path" >/dev/null
    [[ "$(jq length "$robots_file")" == 0 ]]
}
assert_rotated(){
    local ciphertext plaintext
    ciphertext="$(printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice)"
    plaintext="$(printf '%s\n' "$ciphertext" | age -d -i "$identity")"
    [[ "$plaintext" == "publisher-generated-$(jq -r .PUBLISHER_ROBOT_ID "$owner_path")-0123456789abcdef" ]]
    jq -e '.PUBLISHER_ENABLED==true and .RUNTIME_ROBOT_ID==10 and .RUNTIME_USERNAME=="runtime"' "$owner_path" >/dev/null
    [[ "$(jq length "$robots_file")" == 1 ]]
}

# Repeated bounded publication windows, including already-disabled closeout.
for _attempt in 1 2; do
    vx_harbor_publisher_revoke_locked alice "$owner_path"
    assert_disabled; [[ ! -e "$journal" ]]
    vx_harbor_publisher_revoke_locked alice "$owner_path"
    assert_rotated
done

# Upgrade recovery: old disablement left a converged journal on disk.
cp "$journal" "$HARBOR_TEST_ROOT/old-journal"
vx_harbor_publisher_revoke_locked alice "$owner_path"
cp "$HARBOR_TEST_ROOT/old-journal" "$journal"
assert_rotated

# An older disable after authority switch could leave the prior publisher live.
crash_point=authority-switched
if printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice >/dev/null; then fail 'rotation missed crash checkpoint'; fi
_vx_harbor_owned_robot_delete alice publisher vx-alice 1 "$(jq -r .PUBLISHER_ROBOT_ID "$owner_path")"
_vx_harbor_owner_write "$owner_path" "$(jq '.PUBLISHER_ENABLED=false|.PUBLISHER_ROBOT_ID=null|.PUBLISHER_USERNAME=null|.STATE="publisher-disabled"' "$owner_path")"
[[ "$(jq length "$robots_file")" == 1 ]]
crash_point=none; assert_rotated

# Lost create responses and both sides of the authority switch must revoke
# every generation, not just the robot currently named in owner authority.
for phase in prepared candidate-created pending-switch pending-revoke; do
    crash_point='journal-published'
    [[ "$phase" != pending-revoke ]] || crash_point=authority-switched
    status=0
    printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice >"$HARBOR_TEST_ROOT/failed-output" || status=$?
    [[ "$status" == 76 && ! -s "$HARBOR_TEST_ROOT/failed-output" ]]
    new_id="$(jq -r .NEW_ROBOT_ID "$journal")"; new_user="$(jq -r .NEW_USERNAME "$journal")"
    [[ "$phase" != prepared ]] || { new_id=null; new_user=; }
    _vx_harbor_rotation_write alice publisher 1 "$(jq -r .OPERATION_ID "$journal")" "$phase" \
        "$new_id" "$new_user" "$(jq -r .OLD_ROBOT_ID "$journal")"
    vx_harbor_publisher_revoke_locked alice "$owner_path"
    assert_disabled; [[ ! -e "$journal" ]]
    crash_point=none; assert_rotated
done

# An outage deleting the prior generation must retain recovery authority.
crash_point=authority-switched
if printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice >/dev/null; then fail 'rotation missed crash checkpoint'; fi
delete_outage_id="$(jq -r .OLD_ROBOT_ID "$journal")"
before="$(cat "$owner_path")"; before_journal="$(cat "$journal")"
status=0; vx_harbor_publisher_revoke_locked alice "$owner_path" || status=$?
[[ "$status" == 75 && "$(cat "$owner_path")" == "$before" && "$(cat "$journal")" == "$before_journal" ]]
[[ "$(jq length "$robots_file")" == 1 ]]
delete_outage_id=
vx_harbor_publisher_revoke_locked alice "$owner_path"
assert_disabled; crash_point=none; assert_rotated

# Failure before the disabled-state write retains the journal; retry is safe
# even though Harbor has already deleted both robots.
before="$(cat "$owner_path")"
if ( _vx_harbor_owner_write(){ return 76; }; vx_harbor_publisher_revoke_locked alice "$owner_path" ); then
    fail 'disable accepted a failed authority write'
fi
[[ -f "$journal" && "$(cat "$owner_path")" == "$before" && "$(jq length "$robots_file")" == 0 ]]
vx_harbor_publisher_revoke_locked alice "$owner_path"
assert_disabled; assert_rotated

# Failure after the disabled-state write is recovered by the next rotation.
if ( _vx_harbor_rotation_remove(){ return 76; }; vx_harbor_publisher_revoke_locked alice "$owner_path" ); then
    fail 'disable accepted failed journal retirement'
fi
assert_disabled; [[ -f "$journal" ]]; assert_rotated

# Reject a mismatched project before deleting anything; failed recovery is
# bounded, stderr-only and recorded without provider data.
vx_harbor_publisher_revoke_locked alice "$owner_path"
cp "$HARBOR_TEST_ROOT/old-journal" "$journal"
jq '.PROJECT_ID=2' "$journal" >"$HARBOR_TEST_ROOT/wrong-project"
cat "$HARBOR_TEST_ROOT/wrong-project" >"$journal"
before_count="$(cat "$create_count")"; before_deletes="$(cat "$delete_log")"
status=0
printf %s "$recipient" | vx_harbor_publisher_rotate_locked alice >"$HARBOR_TEST_ROOT/out" 2>"$HARBOR_TEST_ROOT/err" || status=$?
[[ "$status" == 1 && ! -s "$HARBOR_TEST_ROOT/out" && "$(cat "$HARBOR_TEST_ROOT/err")" == 'Error: publisher_recovery_failed' ]]
[[ "$(cat "$create_count")" == "$before_count" && "$(cat "$delete_log")" == "$before_deletes" && -f "$journal" ]]
jq -se 'any(.[]; .OPERATION=="publisher-rotation" and .RESULT=="failed" and .REASON=="recovery")' "$(vx_harbor_root)/audit.log" >/dev/null

# Exercise the shipped public adapter and real Vesta error transport. Only
# authentication/lock setup is substituted; recovery reads the invalid journal.
mkdir -p "$VESTA/func/vx/compose" "$VESTA/conf" "$VESTA/log"
cp "$HARBOR_REPO_ROOT/func/main.sh" "$VESTA/func/main.sh"
cat >"$VESTA/func/vx/compose/main.sh" <<'EOF'
is_format_valid(){ :; }; is_object_valid(){ :; }
vx_compose_shell_access_lock_acquire(){ :; }; vx_compose_shell_access_lock_release(){ :; }
vx_compose_registry_lock_acquire(){ :; }; vx_compose_registry_lock_release(){ :; }
EOF
cat >"$VESTA/conf/vesta.conf" <<'EOF'
vx_harbor_provider_lock_acquire(){ :; }; vx_harbor_provider_lock_release(){ :; }
vx_harbor_owner_is_eligible(){ :; }
_vx_harbor_require_root(){ :; }
_vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid(){ id -g; }
_vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
EOF
status=0
printf %s "$recipient" | bash "$HARBOR_REPO_ROOT/bin/v-rotate-user-harbor-registry-publisher" alice \
    >"$HARBOR_TEST_ROOT/out" 2>"$HARBOR_TEST_ROOT/err" || status=$?
[[ "$status" == 1 && ! -s "$HARBOR_TEST_ROOT/out" \
    && "$(cat "$HARBOR_TEST_ROOT/err")" == $'Error: publisher_recovery_failed\nError: Publisher rotation failed' ]]
! grep -REq 'publisher-generated-[0-9]+-0123456789abcdef' "$(vx_harbor_root)" "$delete_log" || fail 'publisher plaintext entered durable state or audit'
printf 'PASS: encrypted publisher rotation, disablement and interrupted closeout recovery\n'
