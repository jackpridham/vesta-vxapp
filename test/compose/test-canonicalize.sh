#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$test_root/fake-ss"
chmod 0755 "$test_root/fake-ss"
export VX_COMPOSE_SS_BIN="$test_root/fake-ss"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/common.sh
source "$repo_root/func/vx/compose/common.sh"
# shellcheck source=func/vx/compose/policy.sh
source "$repo_root/func/vx/compose/policy.sh"
# shellcheck source=func/vx/compose/storage.sh
source "$repo_root/func/vx/compose/storage.sh"
# shellcheck source=func/vx/compose/profile.sh
source "$repo_root/func/vx/compose/profile.sh"
# shellcheck source=func/vx/compose/network.sh
source "$repo_root/func/vx/compose/network.sh"
# shellcheck source=func/vx/compose/ports.sh
source "$repo_root/func/vx/compose/ports.sh"
# shellcheck source=func/vx/compose/volumes.sh
source "$repo_root/func/vx/compose/volumes.sh"
# shellcheck source=func/vx/compose/canonicalize.sh
source "$repo_root/func/vx/compose/canonicalize.sh"

candidate="$test_root/candidate"
export VX_HTTP_PORT=19999
vx_compose_prepare_candidate \
    alice \
    web \
    "$repo_root/test/compose/fixtures/basic-http.compose.yaml" \
    "$candidate"

jq -e '.name == "vx-alice-web"' "$candidate/canonical.json" >/dev/null \
    || fail "canonical project name is wrong"
jq -e '.services.web.labels["vx.managed"] == "yes"' \
    "$candidate/canonical.json" >/dev/null \
    || fail "managed label was not injected"
jq -e '.services.web.labels["vx.user"] == "alice"' \
    "$candidate/canonical.json" >/dev/null \
    || fail "owner label was not injected"
jq -e '.services.web.labels["vx.project"] == "web"' \
    "$candidate/canonical.json" >/dev/null \
    || fail "project label was not injected"
jq -e '
    .networks.default.name == "vx-alice-web_default"
    and .networks.default.labels["vx.managed"] == "yes"
    and .networks.default.labels["vx.user"] == "alice"
    and .networks.default.labels["vx.project"] == "web"
    and .networks.default.labels["vx.network"] == "default"
' "$candidate/canonical.json" >/dev/null \
    || fail "network ownership was not canonicalized"
docker compose --project-name vx-alice-web \
    --project-directory "$candidate" \
    --file "$candidate/canonical.json" config --format json \
    | jq -e '
        .name == "vx-alice-web"
        and .networks.default.name == "vx-alice-web_default"
        and .networks.default.labels["vx.managed"] == "yes"
        and .networks.default.labels["vx.user"] == "alice"
        and .networks.default.labels["vx.project"] == "web"
        and .networks.default.labels["vx.network"] == "default"
        and .services.web.labels["vx.managed"] == "yes"
    ' >/dev/null \
    || fail "Docker Compose did not accept the canonical runtime definition"
jq -e '.services.web.ports[0].host_ip == "127.0.0.1"' \
    "$candidate/canonical.json" >/dev/null \
    || fail "localhost port binding was not canonicalized"
jq -e '.services.web.ports[0].published == "18081"' \
    "$candidate/canonical.json" >/dev/null \
    || fail "caller interpolation environment leaked into canonicalization"
unset VX_HTTP_PORT
vx_compose_candidate_summary_json alice web standard "$candidate" | jq -e '
    .VALID == true
    and .COMPOSE_PROJECT == "vx-alice-web"
    and .SERVICES == ["web"]
    and .SERVICE_SUMMARY.web.IMAGE
        == "nginxinc/nginx-unprivileged:1.27-alpine"
    and .SERVICE_SUMMARY.web.PORTS == ["127.0.0.1:18081:8080/tcp"]
    and (.CANONICAL_SHA256 | test("^[a-f0-9]{64}$"))
    and (has("canonical") | not)
' >/dev/null \
    || fail "safe canonical validation preview is incomplete"
(
    cd "$candidate"
    sha256sum -c canonical.sha256 >/dev/null 2>&1
) || fail "canonical digest does not verify"

second="$test_root/candidate-second"
vx_compose_prepare_candidate \
    alice \
    web \
    "$repo_root/test/compose/fixtures/basic-http.compose.yaml" \
    "$second"
cmp -s "$candidate/canonical.json" "$second/canonical.json" \
    || fail "canonical JSON is not deterministic"

range_candidate="$test_root/candidate-range"
vx_compose_prepare_candidate \
    alice range "$repo_root/test/compose/fixtures/port-range.compose.yaml" \
    "$range_candidate"
jq -e '
    [.services.app.ports[].published]
    == ["19020", "19021", "19022"]
    and all(.services.app.ports[]; .host_ip == "127.0.0.1")
' "$range_candidate/canonical.json" >/dev/null \
    || fail "matching port range was not canonicalized"

protocol_candidate="$test_root/candidate-protocols"
vx_compose_prepare_candidate \
    alice protocols "$repo_root/test/compose/fixtures/tcp-udp.compose.yaml" \
    "$protocol_candidate"
jq -e '
    [.services.app.ports[].protocol] | sort == ["tcp", "udp"]
' "$protocol_candidate/canonical.json" >/dev/null \
    || fail "TCP/UDP mappings were not canonicalized"

no_port_candidate="$test_root/candidate-no-port"
vx_compose_prepare_candidate \
    alice internal "$repo_root/test/compose/fixtures/no-port.compose.yaml" \
    "$no_port_candidate"
jq -e '(.services.app.ports // []) | length == 0' \
    "$no_port_candidate/canonical.json" >/dev/null \
    || fail "internal-only workload gained a published port"

existing="$test_root/candidate-existing"
vx_compose_prepare_candidate \
    alice web "$candidate/compose.yaml" "$existing" standard yes
cmp -s "$candidate/canonical.json" "$existing/canonical.json" \
    || fail "stored canonical Compose input does not revalidate deterministically"
stored_label_drift="$test_root/stored-label-drift.yaml"
sed 's/vx.user: alice/vx.user: mallory/' \
    "$candidate/compose.yaml" >"$stored_label_drift"
if vx_compose_prepare_candidate \
    alice web "$stored_label_drift" "$test_root/stored-label-drift" \
    standard yes 2>/dev/null; then
    fail "stored ownership-label drift was accepted"
fi

unsafe="$test_root/unsafe.yaml"
printf '%s\n' \
    'services:' \
    '  bad:' \
    '    image: alpine:3.20' \
    '    privileged: true' >"$unsafe"
if vx_compose_prepare_candidate alice unsafe "$unsafe" "$test_root/unsafe-out" 2>/dev/null; then
    fail "privileged Compose input was accepted"
fi

unbounded="$test_root/unbounded.yaml"
printf '%s\n' \
    'services:' \
    '  bad:' \
    '    image: alpine:3.20' >"$unbounded"
if vx_compose_prepare_candidate alice unbounded "$unbounded" "$test_root/unbounded-out" 2>/dev/null; then
    fail "unbounded Compose input was accepted"
fi

unsafe_security="$test_root/unsafe-security.yaml"
printf '%s\n' \
    'services:' \
    '  bad:' \
    '    image: alpine:3.20' \
    '    init: true' \
    '    cap_drop: [ALL]' \
    '    security_opt: [no-new-privileges:true, apparmor:unconfined]' \
    '    cpus: 0.25' \
    '    mem_limit: 64m' \
    '    pids_limit: 32' >"$unsafe_security"
if vx_compose_prepare_candidate alice unsafe-security "$unsafe_security" "$test_root/unsafe-security-out" 2>/dev/null; then
    fail "unsafe security option was accepted"
fi

environment_input="$test_root/environment.yaml"
printf '%s\n' \
    'services:' \
    '  bad:' \
    '    image: alpine:3.20' \
    '    init: true' \
    '    cap_drop: [ALL]' \
    '    security_opt: [no-new-privileges:true]' \
    '    cpus: 0.25' \
    '    mem_limit: 64m' \
    '    pids_limit: 32' \
    '    logging:' \
    '      driver: json-file' \
    '      options: {max-size: 10m, max-file: "3"}' \
    '    environment:' \
    '      APP_MODE: production' >"$environment_input"
vx_compose_prepare_candidate \
    alice environment "$environment_input" "$test_root/environment-out"
jq -e '.services.bad.environment.APP_MODE == "production"' \
    "$test_root/environment-out/canonical.json" >/dev/null \
    || fail "literal non-secret environment data was not canonicalized"

ln -s "$repo_root/test/compose/fixtures/basic-http.compose.yaml" "$test_root/link.yaml"
if vx_compose_prepare_candidate alice linked "$test_root/link.yaml" "$test_root/link-out" 2>/dev/null; then
    fail "symlink Compose input was accepted"
fi

echo "Compose canonicalization tests passed."
