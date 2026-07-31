#!/usr/bin/env bash

VX_COMPOSE_BACKUP_POLICY_FIELDS='ENABLED SCHEDULE RETAIN_DAILY RETAIN_WEEKLY ENCRYPTION_REQUIRED REPLICATION_ADAPTER FRESHNESS_SECONDS RESTORE_TEST_INTERVAL_SECONDS LAST_ATTEMPT LAST_SUCCESS NEXT_RUN LAST_ARCHIVE LAST_ERROR REPLICATION_STATE LAST_REPLICATED LAST_RESTORE_TEST RESTORE_TEST_STATE'

vx_compose_backup_policy_path() {
    printf '%s/backup-policy.conf\n' "$(vx_compose_project_root "$1" "$2")"
}

vx_compose_backup_policy_schedule_valid() {
    [[ "$1" =~ ^daily@([01][0-9]|2[0-3]):[0-5][0-9]$ \
        || "$1" =~ ^weekly@(sun|mon|tue|wed|thu|fri|sat)@([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

vx_compose_backup_policy_next_run() {
    local schedule="$1" from="${2:-$(vx_compose_now)}" expression
    vx_compose_backup_policy_schedule_valid "$schedule" || return 1
    case "$schedule" in
        daily@*)
            expression="$(date -u -d "$from" +%F) ${schedule#daily@} UTC"
            [[ "$(date -u -d "$expression" +%s)" -gt "$(date -u -d "$from" +%s)" ]] \
                || expression="tomorrow ${schedule#daily@} UTC"
            ;;
        weekly@*)
            expression="next ${schedule#weekly@}"
            expression="${expression%@*} ${schedule##*@} UTC"
            ;;
    esac
    date -u -d "$expression" +'%Y-%m-%dT%H:%M:%SZ'
}

vx_compose_backup_policy_validate_values() {
    local enabled="$1" schedule="$2" daily="$3" weekly="$4"
    local encryption="$5" adapter="$6" freshness="$7" restore_interval="$8"
    [[ "$enabled" == yes || "$enabled" == no ]] || return 1
    vx_compose_backup_policy_schedule_valid "$schedule" || return 1
    [[ "$daily" =~ ^[0-9]+$ && "$daily" -ge 7 ]] || return 1
    [[ "$weekly" =~ ^[0-9]+$ && "$weekly" -ge 4 ]] || return 1
    [[ "$encryption" == yes || "$encryption" == no ]] || return 1
    [[ "$adapter" == none \
        || "$adapter" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
    [[ "$adapter" == none || "$encryption" == yes ]] || return 1
    [[ "$freshness" =~ ^[1-9][0-9]*$ && "$freshness" -ge 3600 ]] || return 1
    [[ "$restore_interval" =~ ^[1-9][0-9]*$
        && "$restore_interval" -ge 86400 ]] || return 1
}

vx_compose_backup_policy_file_validate() {
    local path="$1" field value count
    local timestamp_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    [[ -f "$path" && ! -L "$path" ]] || return 1
    for field in $VX_COMPOSE_BACKUP_POLICY_FIELDS; do
        read -r count < <(awk -F= -v key="$field" \
            '$1==key {count++} END {print count+0}' "$path")
        [[ "$count" -eq 1 ]] || return 1
    done
    read -r count < <(awk -F= \
        'NF && $1 !~ /^[A-Z_]+$/ {bad++} END {print bad+0}' "$path")
    [[ "$count" -eq 0 ]] || return 1
    read -r count < <(wc -l <"$path")
    [[ "$count" -eq 17 ]] || return 1
    vx_compose_backup_policy_validate_values \
        "$(vx_compose_meta_get "$path" ENABLED)" \
        "$(vx_compose_meta_get "$path" SCHEDULE)" \
        "$(vx_compose_meta_get "$path" RETAIN_DAILY)" \
        "$(vx_compose_meta_get "$path" RETAIN_WEEKLY)" \
        "$(vx_compose_meta_get "$path" ENCRYPTION_REQUIRED)" \
        "$(vx_compose_meta_get "$path" REPLICATION_ADAPTER)" \
        "$(vx_compose_meta_get "$path" FRESHNESS_SECONDS)" \
        "$(vx_compose_meta_get "$path" RESTORE_TEST_INTERVAL_SECONDS)" \
        || return 1
    for field in LAST_ATTEMPT LAST_SUCCESS NEXT_RUN LAST_REPLICATED \
        LAST_RESTORE_TEST; do
        value="$(vx_compose_meta_get "$path" "$field")" || return 1
        [[ -z "$value" || "$value" =~ $timestamp_re ]] \
            || return 1
    done
    value="$(vx_compose_meta_get "$path" LAST_ARCHIVE)" || return 1
    [[ -z "$value" \
        || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[.]tar[.]gz$ ]] \
        || return 1
    value="$(vx_compose_meta_get "$path" LAST_ERROR)" || return 1
    [[ -z "$value" || "$value" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || return 1
    value="$(vx_compose_meta_get "$path" REPLICATION_STATE)" || return 1
    [[ -z "$value" || "$value" =~ ^(succeeded|failed|not-configured)$ ]] || return 1
    value="$(vx_compose_meta_get "$path" RESTORE_TEST_STATE)" || return 1
    [[ -z "$value" || "$value" =~ ^(succeeded|failed)$ ]] || return 1
}

vx_compose_backup_policy_write() {
    local owner="$1" project="$2" enabled="$3" schedule="$4" daily="$5"
    local weekly="$6" encryption="$7" adapter="$8" freshness="$9"
    local restore_interval="${10}" old="${11:-}" path root temp next_run
    root="$(vx_compose_project_root "$owner" "$project")"
    path="$root/backup-policy.conf"
    next_run="$(vx_compose_backup_policy_next_run "$schedule")" || return 1
    temp="$(mktemp "$root/.backup-policy.XXXXXX")" || return 1
    {
        printf "ENABLED='%s'\n" "$enabled"
        printf "SCHEDULE='%s'\n" "$schedule"
        printf "RETAIN_DAILY='%s'\n" "$daily"
        printf "RETAIN_WEEKLY='%s'\n" "$weekly"
        printf "ENCRYPTION_REQUIRED='%s'\n" "$encryption"
        printf "REPLICATION_ADAPTER='%s'\n" "$adapter"
        printf "FRESHNESS_SECONDS='%s'\n" "$freshness"
        printf "RESTORE_TEST_INTERVAL_SECONDS='%s'\n" "$restore_interval"
        for field in LAST_ATTEMPT LAST_SUCCESS LAST_ARCHIVE LAST_ERROR \
            REPLICATION_STATE LAST_REPLICATED LAST_RESTORE_TEST RESTORE_TEST_STATE; do
            printf "%s='%s'\n" "$field" \
                "$(vx_compose_meta_get "$old" "$field" 2>/dev/null || :)"
        done
        printf "NEXT_RUN='%s'\n" "$next_run"
    } >"$temp"
    chmod 0600 "$temp" && mv -f -- "$temp" "$path"
}

vx_compose_backup_policy_restore_reset() {
    local owner="$1" project="$2" archived="$3"
    vx_compose_backup_policy_file_validate "$archived" || return 1
    vx_compose_backup_policy_write "$owner" "$project" \
        "$(vx_compose_meta_get "$archived" ENABLED)" \
        "$(vx_compose_meta_get "$archived" SCHEDULE)" \
        "$(vx_compose_meta_get "$archived" RETAIN_DAILY)" \
        "$(vx_compose_meta_get "$archived" RETAIN_WEEKLY)" \
        "$(vx_compose_meta_get "$archived" ENCRYPTION_REQUIRED)" \
        "$(vx_compose_meta_get "$archived" REPLICATION_ADAPTER)" \
        "$(vx_compose_meta_get "$archived" FRESHNESS_SECONDS)" \
        "$(vx_compose_meta_get "$archived" RESTORE_TEST_INTERVAL_SECONDS)" ''
}

vx_compose_backup_policy_add() {
    local owner="$1" project="$2" enabled="$3" schedule="$4" daily="$5"
    local weekly="$6" encryption="$7" adapter="$8" freshness="$9"
    local restore_interval="${10}" root old
    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_backup_policy_validate_values "$enabled" "$schedule" "$daily" \
        "$weekly" "$encryption" "$adapter" "$freshness" "$restore_interval" \
        || { vx_compose_error 'invalid Compose backup policy'; return 1; }
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    old="$root/backup-policy.conf"
    [[ ! -L "$old" ]] || {
        vx_compose_lock_release
        vx_compose_error 'linked Compose backup policy is not allowed'
        return 1
    }
    vx_compose_backup_policy_write "$owner" "$project" "$enabled" "$schedule" \
        "$daily" "$weekly" "$encryption" "$adapter" "$freshness" \
        "$restore_interval" "$old" || {
            vx_compose_lock_release
            return 1
        }
    vx_compose_audit "$root" backup-policy succeeded \
        "enabled=$enabled schedule=$schedule adapter=$adapter" || :
    vx_compose_lock_release
}

vx_compose_backup_policy_list_json() {
    local owner="$1" project="$2" path json='{}' field value
    vx_compose_require_project "$owner" "$project" || return 1
    path="$(vx_compose_backup_policy_path "$owner" "$project")"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%a' "$path")" == 600 ]] \
        || { printf '{}\n'; return; }
    vx_compose_backup_policy_file_validate "$path" || return 1
    for field in $VX_COMPOSE_BACKUP_POLICY_FIELDS; do
        value="$(vx_compose_meta_get "$path" "$field")" || return 1
        case "$field" in
            RETAIN_DAILY|RETAIN_WEEKLY|FRESHNESS_SECONDS|RESTORE_TEST_INTERVAL_SECONDS)
                json="$(jq -c --arg key "$field" --argjson value "$value" \
                    '.[$key]=$value' <<<"$json")" ;;
            *) json="$(jq -c --arg key "$field" --arg value "$value" \
                    '.[$key]=$value' <<<"$json")" ;;
        esac
    done
    jq -n --arg owner "$owner" --arg project "$project" --argjson policy "$json" \
        '{OWNER:$owner,PROJECT:$project}+ $policy'
}

vx_compose_backup_policy_state_update() {
    local path="$1" field="$2" value="$3" root temp
    case " $VX_COMPOSE_BACKUP_POLICY_FIELDS " in *" $field "*) ;; *) return 1;; esac
    root="$(dirname -- "$path")"
    temp="$(mktemp "$root/.backup-policy.XXXXXX")" || return 1
    awk -v key="$field" -v value="$value" '
        BEGIN { found=0 }
        $0 ~ ("^" key "='\''") { printf "%s='\''%s'\''\n", key, value; found=1; next }
        { print }
        END { if (!found) printf "%s='\''%s'\''\n", key, value }
    ' "$path" >"$temp" || { rm -f -- "$temp"; return 1; }
    chmod 0600 "$temp" && mv -f -- "$temp" "$path"
}

vx_compose_backup_policy_retention() {
    local owner="$1" project="$2" daily="$3" weekly="$4" last_good="${5:-}"
    local root archive epoch day week keep_file remove_file count
    root="$(vx_compose_backup_root "$owner" "$project")"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    keep_file="$(mktemp)" remove_file="$(mktemp)"
    while IFS= read -r -d '' archive; do
        [[ "$(realpath -e -- "$(dirname -- "$archive")")" == "$(realpath -e -- "$root")" ]] \
            || continue
        epoch="$(stat -c %Y "$archive")"
        day="$(date -u -d "@$epoch" +%F)"
        week="$(date -u -d "@$epoch" +%G-W%V)"
        printf '%s\t%s\t%s\t%s\n' "$epoch" "$day" "$week" "$archive"
    done < <(find "$root" -maxdepth 1 -type f -name '*.tar.gz' -print0) \
        | sort -rn >"$remove_file"
    count=0
    while IFS=$'\t' read -r epoch day week archive; do
        ((++count))
        [[ "$count" -le "$daily" ]] && printf '%s\n' "$archive" >>"$keep_file"
    done < <(awk -F '\t' '!seen[$2]++' "$remove_file")
    count=0
    while IFS=$'\t' read -r epoch day week archive; do
        ((++count))
        [[ "$count" -le "$weekly" ]] && printf '%s\n' "$archive" >>"$keep_file"
    done < <(awk -F '\t' '!seen[$3]++' "$remove_file")
    [[ -z "$last_good" ]] || printf '%s/%s\n' "$root" "$last_good" >>"$keep_file"
    while IFS=$'\t' read -r epoch day week archive; do
        grep -Fxq -- "$archive" "$keep_file" || rm -f -- "$archive"
    done <"$remove_file"
    rm -f -- "$keep_file" "$remove_file"
}

vx_compose_backup_replication_adapter_path() {
    local name="$1" path
    path="$VESTA/func/vx/compose/replication-adapters/$name"
    [[ "$name" != none && -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
    if [[ "$EUID" -eq 0 ]]; then
        [[ "$(stat -c %u "$path")" -eq 0 \
            && $((8#$(stat -c %a "$path") & 8#022)) -eq 0 ]] || return 1
    fi
    printf '%s\n' "$path"
}

vx_compose_backup_replicate() {
    local owner="$1" project="$2" adapter="$3" archive="$4" executable result
    [[ "$adapter" != none ]] || { printf '{"STATE":"not-configured"}\n'; return; }
    executable="$(vx_compose_backup_replication_adapter_path "$adapter")" \
        || { printf '{"STATE":"not-configured"}\n'; return; }
    result="$("$executable" "$owner" "$project" 3<"$archive" 2>/dev/null)" \
        || { printf '{"STATE":"failed"}\n'; return 1; }
    jq -ce 'select(type=="object" and
        (.STATE=="succeeded" or .STATE=="failed" or .STATE=="not-configured"))
        | select((.REFERENCE // "") | type=="string" and length<=256
            and test("^[A-Za-z0-9:._/-]*$"))
        | {STATE,REFERENCE:(.REFERENCE // "")}' <<<"$result" \
        || { printf '{"STATE":"failed"}\n'; return 1; }
}

vx_compose_backup_restore_drill() {
    local owner="$1" project="$2" archive="$3" root output result=1
    root="$(vx_compose_project_root "$owner" "$project")"
    output="$(mktemp -d "$root/runtime/.restore-drill.XXXXXX")" || return 1
    rmdir "$output"
    vx_compose_restore_archive_validate "$owner" "$project" "$archive" "$output" \
        && result=0
    rm -rf -- "$output"
    return "$result"
}

_vx_compose_backup_policy_run_locked() {
    local owner="$1" project="$2" path root now archive policy encryption adapter
    local replication restore_due=no result=1 replication_input encrypted_payload=''
    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    path="$root/backup-policy.conf"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%a' "$path")" == 600 ]] || {
        vx_compose_lock_release; vx_compose_error 'Compose backup policy is not configured'; return 1;
    }
    policy="$(vx_compose_backup_policy_list_json "$owner" "$project")" || {
        vx_compose_lock_release; return 1;
    }
    now="$(vx_compose_now)"
    vx_compose_backup_policy_state_update "$path" LAST_ATTEMPT "$now" || :
    encryption="$(jq -r .ENCRYPTION_REQUIRED <<<"$policy")"
    if [[ "$encryption" == yes ]] \
        && { [[ -z "${VX_DOCKER_AGE_RECIPIENT:-}" ]] \
            || ! command -v age >/dev/null 2>&1; }; then
        vx_compose_backup_policy_state_update "$path" LAST_ERROR encryption-unavailable
        vx_compose_backup_alert_set "$owner" "$project" encryption-unavailable \
            'backup encryption is unavailable'
        vx_compose_audit "$root" backup-policy-run failed encryption-unavailable || :
        vx_compose_lock_release
        return 1
    fi
    archive="$(vx_compose_backup_allocate_path "$owner" "$project")" \
        && vx_compose_backup_project "$owner" "$project" "$archive" \
        && vx_compose_restore_archive_validate "$owner" "$project" "$archive" \
            "$root/runtime/.backup-validation.$BASHPID" \
        && rm -rf -- "$root/runtime/.backup-validation.$BASHPID" \
        || archive=''
    if [[ -n "$archive" ]]; then
        adapter="$(jq -r .REPLICATION_ADAPTER <<<"$policy")"
        replication_input="$archive"
        if [[ "$encryption" == yes ]]; then
            encrypted_payload="$(mktemp "$root/runtime/.backup-replication.XXXXXX.age")" \
                || encrypted_payload=''
            if [[ -z "$encrypted_payload" ]] \
                || ! chmod 0600 "$encrypted_payload" \
                || ! vx_compose_age_encrypt "$archive" "$encrypted_payload" \
                || cmp -s "$archive" "$encrypted_payload"; then
                rm -f -- "$encrypted_payload"
                vx_compose_backup_policy_state_update "$path" LAST_ERROR \
                    encryption-unavailable
                vx_compose_backup_alert_set "$owner" "$project" \
                    encryption-unavailable 'backup encryption is unavailable'
                vx_compose_audit "$root" backup-policy-run failed \
                    encryption-unavailable || :
                vx_compose_lock_release
                return 1
            fi
            replication_input="$encrypted_payload"
        fi
        replication="$(vx_compose_backup_replicate \
            "$owner" "$project" "$adapter" "$replication_input")" || :
        rm -f -- "$encrypted_payload"
        vx_compose_backup_policy_state_update "$path" REPLICATION_STATE \
            "$(jq -r '.STATE // "failed"' <<<"$replication")"
        case "$(jq -r '.STATE // "failed"' <<<"$replication")" in
            succeeded)
                vx_compose_backup_policy_state_update "$path" LAST_REPLICATED "$now"
                vx_compose_backup_alert_close "$owner" "$project" \
                    replication-failure
                vx_compose_backup_alert_close "$owner" "$project" \
                    replication-lag
                ;;
            not-configured)
                vx_compose_backup_alert_set "$owner" "$project" replication-lag \
                    'off-host replication is not configured'
                ;;
            *)
                vx_compose_backup_alert_set "$owner" "$project" \
                    replication-failure 'off-host replication failed'
                ;;
        esac
        if [[ -z "$(jq -r .LAST_RESTORE_TEST <<<"$policy")" \
            || $(( $(date -u -d "$now" +%s) - $(date -u -d \
                "$(jq -r '.LAST_RESTORE_TEST // "1970-01-01T00:00:00Z"' <<<"$policy")" +%s) )) \
                -ge "$(jq -r .RESTORE_TEST_INTERVAL_SECONDS <<<"$policy")" ]]; then
            restore_due=yes
        fi
        if [[ "$restore_due" == yes ]]; then
            if vx_compose_backup_restore_drill "$owner" "$project" "$archive"; then
                vx_compose_backup_policy_state_update "$path" RESTORE_TEST_STATE succeeded
                vx_compose_backup_policy_state_update "$path" LAST_RESTORE_TEST "$now"
            else
                vx_compose_backup_policy_state_update "$path" RESTORE_TEST_STATE failed
                vx_compose_backup_alert_set "$owner" "$project" restore-test-failure \
                    'validation-only restore failed'
            fi
        fi
        vx_compose_backup_policy_state_update "$path" LAST_SUCCESS "$now"
        vx_compose_backup_policy_state_update "$path" LAST_ARCHIVE "$(basename -- "$archive")"
        vx_compose_backup_policy_state_update "$path" LAST_ERROR ''
        vx_compose_backup_policy_state_update "$path" NEXT_RUN \
            "$(vx_compose_backup_policy_next_run "$(jq -r .SCHEDULE <<<"$policy")" "$now")"
        vx_compose_backup_policy_retention "$owner" "$project" \
            "$(jq -r .RETAIN_DAILY <<<"$policy")" \
            "$(jq -r .RETAIN_WEEKLY <<<"$policy")" "$(basename -- "$archive")"
        vx_compose_audit "$root" backup-policy-run succeeded \
            "archive=$(basename -- "$archive") replication=$(jq -r .STATE <<<"$replication")" || :
        result=0
    else
        rm -rf -- "$root/runtime/.backup-validation.$BASHPID"
        vx_compose_backup_policy_state_update "$path" LAST_ERROR backup-failed
        vx_compose_backup_alert_set "$owner" "$project" backup-failure 'managed backup failed'
        vx_compose_audit "$root" backup-policy-run failed backup-failed || :
    fi
    vx_compose_lock_release
    return "$result"
}

vx_compose_backup_policy_run() {
    local owner="$1" project="$2" root run_lock run_fd result
    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    install -d -m 0750 "$root/runtime" || return 1
    run_lock="$root/runtime/backup-policy-run.lock"
    exec {run_fd}>"$run_lock" || return 1
    chmod 0600 "$run_lock" || { exec {run_fd}>&-; return 1; }
    flock -n "$run_fd" || {
        exec {run_fd}>&-
        vx_compose_error 'Compose backup policy run is already active'
        return 1
    }
    if _vx_compose_backup_policy_run_locked "$owner" "$project"; then
        result=0
    else
        result=$?
    fi
    flock -u "$run_fd" || :
    exec {run_fd}>&-
    return "$result"
}

vx_compose_backup_policies_run_due() {
    local lock="$VESTA/data/locks/compose-backup-scheduler.lock" fd now owner project path
    install -d -m 0750 "$(dirname -- "$lock")" || return 1
    exec {fd}>"$lock" || return 1
    flock -n "$fd" || { exec {fd}>&-; return 0; }
    now="$(date -u +%s)"
    while IFS=$'\t' read -r owner project path; do
        vx_compose_backup_policy_file_validate "$path" || continue
        [[ "$(vx_compose_meta_get "$path" ENABLED 2>/dev/null)" == yes ]] || continue
        [[ "$(date -u -d "$(vx_compose_meta_get "$path" NEXT_RUN)" +%s)" -le "$now" ]] \
            || continue
        vx_compose_backup_policy_run "$owner" "$project" || :
    done < <(
        find "$VESTA/data/users" -mindepth 4 -maxdepth 4 -type f \
            -path '*/docker-projects/*/backup-policy.conf' -perm 0600 -print0 \
            | while IFS= read -r -d '' path; do
                project="$(basename -- "$(dirname -- "$path")")"
                owner="$(basename -- "$(dirname -- "$(dirname -- "$(dirname -- "$path")")")")"
                vx_compose_owner_is_valid "$owner" \
                    && vx_compose_project_is_valid "$project" \
                    && printf '%s\t%s\t%s\n' "$owner" "$project" "$path"
            done | sort
    )
    flock -u "$fd"; exec {fd}>&-
}

vx_compose_backup_alerts_evaluate_policy() {
    local owner="$1" project="$2" path now last next freshness replication
    local last_error restore_state type active message
    vx_compose_require_project "$owner" "$project" || return 1
    path="$(vx_compose_backup_policy_path "$owner" "$project")"
    [[ -f "$path" && ! -L "$path" ]] || return 0
    now="$(date -u +%s)"
    last="$(vx_compose_meta_get "$path" LAST_SUCCESS 2>/dev/null || :)"
    next="$(vx_compose_meta_get "$path" NEXT_RUN 2>/dev/null || :)"
    freshness="$(vx_compose_meta_get "$path" FRESHNESS_SECONDS 2>/dev/null || :)"
    replication="$(vx_compose_meta_get "$path" REPLICATION_STATE 2>/dev/null || :)"
    last_error="$(vx_compose_meta_get "$path" LAST_ERROR 2>/dev/null || :)"
    restore_state="$(vx_compose_meta_get "$path" RESTORE_TEST_STATE 2>/dev/null || :)"
    for type in missed-run backup-failure freshness-breach \
        encryption-unavailable replication-lag replication-failure \
        restore-test-failure; do
        active=no
        message="$type"
        case "$type" in
        missed-run)
            [[ -n "$next" \
                && "$(date -u -d "$next" +%s 2>/dev/null || echo 0)" -lt "$now" ]] \
                && { active=yes; message='scheduled backup is overdue'; } ;;
        backup-failure)
            [[ "$last_error" == backup-failed ]] \
                && { active=yes; message='managed backup failed'; } ;;
        encryption-unavailable)
            [[ "$last_error" == encryption-unavailable ]] \
                && { active=yes; message='backup encryption is unavailable'; } ;;
        freshness-breach)
            if [[ "$freshness" =~ ^[1-9][0-9]*$ \
        && ( -z "$last" \
            || $((now - $(date -u -d "$last" +%s 2>/dev/null || echo 0))) -gt "$freshness" ) ]]; then
                active=yes; message='last successful backup exceeds freshness objective'
            fi ;;
        replication-lag)
            [[ "$replication" == not-configured ]] \
                && { active=yes; message='off-host replication is not configured'; } ;;
        replication-failure)
            [[ "$replication" == failed ]] \
                && { active=yes; message='off-host replication failed'; } ;;
        restore-test-failure)
            [[ "$restore_state" == failed ]] \
                && { active=yes; message='validation-only restore failed'; } ;;
        esac
        if [[ "$active" == yes ]]; then
            vx_compose_backup_alert_set "$owner" "$project" "$type" "$message"
        else
            vx_compose_backup_alert_close "$owner" "$project" "$type"
        fi
    done
}
