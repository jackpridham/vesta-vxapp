#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

web_parent="/tmp/vx-compose-web.0123456789abcdef0123456789abcdef"
rm -rf -- "$web_parent"
mkdir -m 0700 "$web_parent"
printf 'services: {}\n' >"$web_parent/compose.yaml"
chmod 0600 "$web_parent/compose.yaml"

vx_compose_web_source_validate "$web_parent/compose.yaml" compose.yaml \
    || fail "valid protected web source was rejected"
[[ "$VX_COMPOSE_WEB_SOURCE_PARENT" == "$web_parent" ]] \
    || fail "validated web source parent is wrong"

if vx_compose_web_source_validate "$web_parent/compose.yaml" simple.spec \
    2>/dev/null; then
    fail "web source accepted the wrong exact filename"
fi
chmod 0644 "$web_parent/compose.yaml"
if vx_compose_web_source_validate "$web_parent/compose.yaml" compose.yaml \
    2>/dev/null; then
    fail "web source accepted an unsafe file mode"
fi
chmod 0600 "$web_parent/compose.yaml"
touch -d '20 minutes ago' "$web_parent/compose.yaml"
if vx_compose_web_source_validate "$web_parent/compose.yaml" compose.yaml \
    2>/dev/null; then
    fail "web source accepted an expired file"
fi
touch "$web_parent/compose.yaml"

vx_compose_web_source_validate "$web_parent/compose.yaml" compose.yaml
vx_compose_web_source_cleanup "$web_parent/compose.yaml"
[[ ! -e "$web_parent" ]] \
    || fail "web source cleanup did not remove the exact temporary directory"

grep -Fq 'vx_compose_web_source_validate "$source" compose.yaml' \
    "$repo_root/func/vx/compose/deployment.sh" \
    || fail "preview staging does not validate the protected web source"
grep -Fq 'vx_compose_preview_consume_web_source' \
    "$repo_root/func/vx/compose/deployment.sh" \
    || fail "preview staging does not identity-bind protected source cleanup"

grep -Fq "'v-stage-docker-project-preview'," \
    "$repo_root/web/inc/vx_compose.php" \
    || fail "panel helper does not allow immutable preview staging"
grep -Fq "'v-list-docker-project-definition'," \
    "$repo_root/web/inc/vx_compose.php" \
    || fail "panel helper does not allow safe definition export"
if grep -Eq "preview.*\\['source'\\]" \
    "$repo_root/web/add/docker/project/index.php" \
    "$repo_root/web/edit/docker/project/index.php"; then
    fail "panel preview session retains a mutable source path"
fi

run_controller_case() {
    local kind="$1" scenario="$2"
    if command -v php >/dev/null 2>&1; then
        php -n "$repo_root/test/test_compose_php_helpers.php" \
            controller "$kind" "$scenario"
    else
        docker run --rm -v "$repo_root:/workspace:ro" -w /workspace \
            php:8.2-cli php -n test/test_compose_php_helpers.php \
            controller "$kind" "$scenario"
    fi
}

for kind in add edit; do
    result="$(run_controller_case "$kind" stage)"
    jq -e --arg mode "$([ "$kind" = add ] && echo add || echo change)" '
        any(.commands[];
            .[0] == "v-stage-docker-project-preview"
            and .[1][0] == "alice"
            and .[1][1] == "alice"
            and .[1][4] == "standard"
            and .[1][5] == $mode)
        and (.spawns | length == 0)
        and (.html | contains("docker-impact-card"))
        and (.html | contains("Services added"))
    ' <<<"$result" >/dev/null \
        || fail "$kind ordinary-owner POST did not reach standard staging"

    result="$(run_controller_case "$kind" unsafe_stage)"
    jq -e '
        (.spawns | length == 0)
        and (.error == "Compose project validation failed.")
        and (.html | contains("compose-deploy-confirm-form") | not)
        and (.html | contains("compose-update-confirm-form") | not)
        and (.html | contains("secret-canary-value") | not)
        and (.html | contains("vx-compose-web") | not)
        and ((.session | tostring) | contains("secret-canary-value") | not)
        and ((.session | tostring) | contains("vx-compose-web") | not)
        and ((.session | tostring) | contains("simple.spec") | not)
    ' <<<"$result" >/dev/null \
        || fail "$kind rendered or retained unsafe stage output"

    result="$(run_controller_case "$kind" apply)"
    expected_revision="$([ "$kind" = add ] && echo 0 || echo 2)"
    jq -e --arg revision "'$expected_revision'" '
        (.spawns | length == 1)
        and (.spawns[0] | contains("v-apply-docker-project-preview"))
        and (.spawns[0] | contains(
            "'\''alice'\'' '\''alice'\'' '\''app'\''"
        ))
        and (.spawns[0] | contains(
            "'\''cccccccccccccccccccccccccccccccc'\''"
        ))
        and (.spawns[0] | contains(
            "'\''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\''"
        ))
        and (.spawns[0] | contains(
            "'\''bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\''"
        ))
        and (.spawns[0] | endswith($revision))
        and (.spawns[0] | contains("v-web-add-docker-project") | not)
        and (.spawns[0] | contains("v-web-change-docker-project") | not)
    ' <<<"$result" >/dev/null \
        || fail "$kind ordinary-owner POST did not reach immutable apply"

    for not_ready in not_ready_stage not_ready_apply; do
        result="$(run_controller_case "$kind" "$not_ready")"
        jq -e '
            (.spawns | length == 0)
            and all(.commands[];
                .[0] != "v-stage-docker-project-preview"
                and .[0] != "v-apply-docker-project-preview"
                and .[0] != "v-web-add-docker-project"
                and .[0] != "v-web-change-docker-project"
            )
            and (.error == "Docker orchestration prerequisites are unavailable.")
        ' <<<"$result" >/dev/null \
            || fail "$kind accepted orchestration-unready POST: $not_ready"
    done

    for blocked in cross_owner admin-approved stale_csrf \
        altered_digest stale_preview unknown_preview forgotten_preview; do
        result="$(run_controller_case "$kind" "$blocked")"
        jq -e '
            (.spawns | length == 0)
            and (any(.commands[]; .[0] == "v-stage-docker-project-preview") | not)
        ' <<<"$result" >/dev/null \
            || fail "$kind accepted blocked POST case: $blocked"
        if [ "$blocked" = cross_owner ]; then
            jq -e '.commands | length == 0' <<<"$result" >/dev/null \
                || fail "$kind cross-owner POST reached a command"
        fi
        case "$blocked" in
            stale_preview|unknown_preview|forgotten_preview)
                jq -e '.error != ""' <<<"$result" >/dev/null \
                    || fail "$kind $blocked did not report an error"
                ;;
        esac
    done
done

result="$(run_controller_case add admin_expiry_altered)"
jq -e '
    (.spawns | length == 0)
    and (any(.commands[];
        .[0] == "v-web-add-docker-project"
        or .[0] == "v-stage-docker-project-preview") | not)
    and (.error | contains("altered"))
' <<<"$result" >/dev/null \
    || fail "add accepted an altered admin-approved expiry"

echo "Compose web job source tests passed."
