#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/harbor/lib.sh
source "$test_dir/lib.sh"

if [[ -n "${HARBOR_TEST_RUN_ROOT:-}" ]]; then
    HARBOR_TEST_ROOT="$(dirname "$HARBOR_TEST_RUN_ROOT")"
    VESTA="$HARBOR_TEST_RUN_ROOT"
    export HARBOR_TEST_ROOT VESTA
    mkdir -p "$VESTA/data/harbor" "$VESTA/data/users" "$VESTA/func/vx"
    chmod 0700 "$VESTA/data/harbor"
else
    new_vesta_root
    trap cleanup_vesta_root EXIT
fi

python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$test_dir/fixtures/fake-harbor-api.py" "$HARBOR_TEST_ROOT/fake-harbor-api.pyc"
bash -n "$test_dir/fixtures/fake-docker.sh"
bash -n "$test_dir/fixtures/fake-systemctl.sh"

assert_file "$HARBOR_REPO_ROOT/.docs/contracts/harbor-provider.md"
assert_file "$HARBOR_REPO_ROOT/func/vx/harbor/main.sh"
install_harbor_helpers

assert_file "$HARBOR_REPO_ROOT/func/vx/harbor/common.sh"
assert_file "$HARBOR_REPO_ROOT/func/vx/harbor/audit.sh"
# shellcheck source=func/vx/harbor/main.sh
source "$VESTA/func/vx/harbor/main.sh"

[[ "$(_vx_harbor_authority_uid)" == 0 ]] \
    || fail 'production provider authority UID is not root'
[[ "$(_vx_harbor_authority_gid)" == 0 ]] \
    || fail 'production provider authority GID is not root'
if (( EUID != 0 )); then
    preexisting_root_mode="$(stat -c '%u:%g:%a' "$VESTA/data/harbor")"
    non_root_source="$HARBOR_TEST_ROOT/non-root-source.json"
    printf '{}\n' >"$non_root_source"
    if vx_harbor_provider_prepare 2>/dev/null; then
        fail 'non-root provider preparation was accepted'
    fi
    [[ "$(stat -c '%u:%g:%a' "$VESTA/data/harbor")" == "$preexisting_root_mode" ]] \
        || fail 'rejected non-root authority was mutated'
    if vx_harbor_json_write_atomic "$VESTA/data/harbor/non-root.json" \
        "$non_root_source" 2>/dev/null; then
        fail 'non-root atomic provider mutation was accepted'
    fi
    if vx_harbor_provider_lock_acquire exclusive 2>/dev/null; then
        fail 'non-root provider lock mutation was accepted'
    fi
    if vx_harbor_audit system provider-prepare failed non-root 2>/dev/null; then
        fail 'non-root provider audit mutation was accepted'
    fi
fi

# Production helpers above always require root:root. The isolated harness
# substitutes private functions only after sourcing so it can exercise the
# same state behavior without granting inherited environment control.
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }

assert_mode() {
    [[ "$(stat -c '%a' "$1")" == "$2" ]] || fail "unexpected mode for $1"
}

path_fixture="$HARBOR_TEST_ROOT/path-authority"
mkdir -m 0700 "$path_fixture"
_vx_harbor_directory_prepare "$path_fixture/created" "$path_fixture" "$path_fixture"
assert_mode "$path_fixture/created" 700

mkdir -m 0755 "$path_fixture/wrong-mode"
if _vx_harbor_directory_prepare "$path_fixture/wrong-mode" "$path_fixture" \
    "$path_fixture" 2>/dev/null; then
    fail 'wrong-mode existing authority directory was accepted'
fi
assert_mode "$path_fixture/wrong-mode" 755

mkdir -m 0755 "$path_fixture/symlink-target"
ln -s "$path_fixture/symlink-target" "$path_fixture/symlink-leaf"
if _vx_harbor_directory_prepare "$path_fixture/symlink-leaf" "$path_fixture" \
    "$path_fixture" 2>/dev/null; then
    fail 'symlinked authority leaf was accepted'
fi
assert_mode "$path_fixture/symlink-target" 755

mkdir -m 0755 "$path_fixture/intermediate-target"
ln -s "$path_fixture/intermediate-target" "$path_fixture/intermediate"
if _vx_harbor_directory_prepare "$path_fixture/intermediate/leaf" \
    "$path_fixture/intermediate" "$path_fixture" 2>/dev/null; then
    fail 'symlinked authority intermediate was accepted'
fi
assert_mode "$path_fixture/intermediate-target" 755

printf 'authority\n' >"$path_fixture/hardlink-target"
ln "$path_fixture/hardlink-target" "$path_fixture/hardlink-leaf"
if _vx_harbor_directory_prepare "$path_fixture/hardlink-leaf" "$path_fixture" \
    "$path_fixture" 2>/dev/null; then
    fail 'hard-linked non-directory authority leaf was accepted'
fi
[[ "$(<"$path_fixture/hardlink-target")" == authority ]] \
    || fail 'rejected hard-linked target was mutated'

if (( EUID != 0 )); then
    mkdir -m 0755 "$path_fixture/wrong-owner"
    _vx_harbor_authority_uid() { printf '0\n'; }
    _vx_harbor_authority_gid() { printf '0\n'; }
    if _vx_harbor_directory_prepare "$path_fixture/wrong-owner/leaf" \
        "$path_fixture/wrong-owner" "$path_fixture" 2>/dev/null; then
        fail 'wrong-owner existing authority component was accepted'
    fi
    assert_mode "$path_fixture/wrong-owner" 755
    [[ ! -e "$path_fixture/wrong-owner/leaf" ]] \
        || fail 'rejected wrong-owner component was mutated'
    _vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
    _vx_harbor_authority_gid() { id -g; }
fi

preflight_root="$VESTA/data/harbor-preflight"
mkdir -m 0700 "$preflight_root"
mkdir -m 0755 "$preflight_root/observations"
vx_harbor_root() { printf '%s\n' "$preflight_root"; }
if vx_harbor_provider_prepare 2>/dev/null; then
    fail 'provider preparation accepted a later wrong-mode component'
fi
[[ ! -e "$preflight_root/owners" ]] \
    || fail 'provider preparation mutated paths before authenticating all components'
assert_mode "$preflight_root/observations" 755
vx_harbor_root() { printf '%s\n' "$VESTA/data/harbor"; }

race_root="$VESTA/data/harbor-provider-race"
mkdir -m 0700 "$race_root"
vx_harbor_root() { printf '%s\n' "$race_root"; }
_vx_harbor_provider_prepare_after_preflight() {
    printf '{"SCHEMA":1,"MODE":"disabled"}\n' >"$race_root/provider.json"
    _vx_harbor_secure_file_set "$race_root/provider.json" 0600
}
if vx_harbor_provider_prepare 2>/dev/null; then
    fail 'provider appearing after preflight bypassed exact schema validation'
fi
vx_harbor_provider_state_validate "$race_root/provider.json" >/dev/null 2>&1 \
    && fail 'race-injected malformed provider state unexpectedly validated'
_vx_harbor_provider_prepare_after_preflight() { :; }
vx_harbor_root() { printf '%s\n' "$VESTA/data/harbor"; }

vx_harbor_provider_prepare
root="$VESTA/data/harbor"
[[ "$(vx_harbor_root)" == "$root" ]] || fail 'provider root is incorrect'
[[ "$(vx_harbor_data_root)" == /var/lib/vesta-harbor ]] || fail 'data root is incorrect'
for directory in "$root" "$root/owners" "$root/observations" "$root/secrets" \
    "$root/release" "$root/backups" "$root/locks"; do
    [[ -d "$directory" && ! -L "$directory" ]] || fail "missing secure directory: $directory"
    assert_mode "$directory" 700
    [[ "$(stat -c '%u:%g' "$directory")" == "$EUID:$(id -g)" ]] \
        || fail "unexpected test authority owner for $directory"
done
assert_mode "$root/provider.json" 600
vx_harbor_secure_regular_file "$root/provider.json" 0600 \
    || fail 'provider state is not a secure regular file'
jq -e -S 'keys == [
    "INSTALLATION_ID", "LAST_BACKUP_ID", "LAST_HEALTH_AT",
    "LAST_RESTORE_TEST_AT", "LAST_UPGRADE", "MODE", "ORIGIN",
    "PINNED_VERSION", "RELEASE_MANIFEST_SHA256", "RUNNING_VERSION", "SCHEMA"
] and . == {
    SCHEMA: 1, MODE: "disabled", PINNED_VERSION: "v2.15.0",
    RUNNING_VERSION: null, INSTALLATION_ID: null, ORIGIN: null,
    RELEASE_MANIFEST_SHA256: null, LAST_HEALTH_AT: null,
    LAST_BACKUP_ID: null, LAST_RESTORE_TEST_AT: null, LAST_UPGRADE: null
}' "$root/provider.json" >/dev/null || fail 'initial provider state is incorrect'
[[ "$(vx_harbor_provider_mode)" == disabled ]] || fail 'provider mode is not disabled'
if vx_harbor_provider_enabled; then
    fail 'disabled provider reported enabled'
fi

valid_provider_state="$HARBOR_TEST_ROOT/valid-provider.json"
cp "$root/provider.json" "$valid_provider_state"
assert_invalid_provider_state() {
    local description="$1"
    local content="$2"
    printf '%s\n' "$content" >"$root/provider.json"
    chmod 0600 "$root/provider.json"
    if vx_harbor_provider_state_validate "$root/provider.json"; then
        fail "$description passed exact provider-state validation"
    fi
    if vx_harbor_provider_mode >/dev/null 2>&1; then
        fail "$description was loaded as provider mode"
    fi
    if vx_harbor_provider_prepare >/dev/null 2>&1; then
        fail "$description was accepted during provider preparation"
    fi
    cp "$valid_provider_state" "$root/provider.json"
    chmod 0600 "$root/provider.json"
}
assert_invalid_provider_state truncated '{"SCHEMA":1,"MODE":"disabled"}'
assert_invalid_provider_state wrong-type "$(jq '.LAST_HEALTH_AT = 42' "$valid_provider_state")"
assert_invalid_provider_state extra-key "$(jq '.EXTRA = true' "$valid_provider_state")"
assert_invalid_provider_state wrong-mode "$(jq '.MODE = "enabled"' "$valid_provider_state")"
assert_invalid_provider_state wrong-schema "$(jq '.SCHEMA = 2' "$valid_provider_state")"
assert_invalid_provider_state wrong-pin "$(jq '.PINNED_VERSION = "v2.14.0"' "$valid_provider_state")"
assert_invalid_provider_state malformed '{'
vx_harbor_provider_state_validate "$root/provider.json" \
    || fail 'restored exact provider state was rejected'

state_digest="$(sha256sum "$root/provider.json")"
vx_harbor_provider_prepare
[[ "$(sha256sum "$root/provider.json")" == "$state_digest" ]] \
    || fail 'provider preparation replaced existing authority'

[[ "$(vx_harbor_owner_state_path alice)" == "$root/owners/alice.json" ]] \
    || fail 'owner state path is incorrect'
for invalid_owner in '' Alice ../alice 'alice/name' 'alice.name'; do
    if vx_harbor_owner_state_path "$invalid_owner" >/dev/null 2>&1; then
        fail "invalid owner was accepted: $invalid_owner"
    fi
done

atomic_source="$HARBOR_TEST_ROOT/atomic-source.json"
atomic_destination="$root/observations/provider.json"
printf '{"z":1,"a":{"d":2,"b":1}}\n' >"$atomic_source"
vx_harbor_json_write_atomic "$atomic_destination" "$atomic_source"
[[ "$(<"$atomic_destination")" == $'{\n  "a": {\n    "b": 1,\n    "d": 2\n  },\n  "z": 1\n}' ]] \
    || fail 'atomic JSON was not sorted'
assert_mode "$atomic_destination" 600
[[ -z "$(find "$(dirname "$atomic_destination")" -maxdepth 1 -name '.harbor-json.*' -print)" ]] \
    || fail 'atomic JSON temporary file remained'
printf '{\n' >"$atomic_source"
if vx_harbor_json_write_atomic "$atomic_destination" "$atomic_source" 2>/dev/null; then
    fail 'malformed JSON was accepted'
fi
jq -e '.z == 1' "$atomic_destination" >/dev/null \
    || fail 'failed atomic write changed destination'
hardlink="$root/observations/provider-hardlink.json"
ln "$atomic_destination" "$hardlink"
if vx_harbor_secure_regular_file "$atomic_destination" 0600; then
    fail 'multi-link authority file was accepted'
fi
rm "$hardlink"

vx_harbor_provider_lock_acquire shared
vx_harbor_provider_lock_acquire shared
[[ "$VX_HARBOR_PROVIDER_LOCK_DEPTH" == 2 ]] || fail 'shared lock did not nest'
if vx_harbor_provider_lock_acquire exclusive; then
    fail 'shared-to-exclusive lock inversion was accepted'
fi
vx_harbor_provider_lock_release
vx_harbor_provider_lock_release
if vx_harbor_provider_lock_acquire invalid; then
    fail 'invalid lock mode was accepted'
fi
vx_harbor_provider_lock_acquire exclusive
vx_harbor_provider_lock_acquire exclusive
if vx_harbor_provider_lock_acquire shared; then
    fail 'exclusive-to-shared lock inversion was accepted'
fi
vx_harbor_provider_lock_release
vx_harbor_provider_lock_release
if vx_harbor_provider_lock_release; then
    fail 'unheld provider lock was released'
fi

mkdir -p "$VESTA/nginx/conf"
hostname_file="$HARBOR_TEST_ROOT/hostname"
certificate="$HARBOR_TEST_ROOT/panel.pem"
key="$HARBOR_TEST_ROOT/panel.key"
printf 'panel.example.com\n' >"$hostname_file"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=panel.example.com' -addext 'subjectAltName=DNS:panel.example.com' \
    -keyout "$key" -out "$certificate" >/dev/null 2>&1
write_nginx() {
    printf 'http {\n  server {\n    root /srv/unrelated;\n    listen 9443 ssl;\n    ssl_certificate %s;\n  }\n  server {\n    root %s/web;\n    listen 8083 ssl;\n    ssl_certificate %s;\n  }\n}\n' \
        "$certificate" "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
}
write_nginx
_vx_harbor_authoritative_hostname() {
    awk 'NF { print; found++ } END { if (found != 1) exit 1 }' "$hostname_file"
}
untrusted_hostname_file="$HARBOR_TEST_ROOT/untrusted-hostname"
printf 'attacker.example.com\n' >"$untrusted_hostname_file"
export VX_HARBOR_HOSTNAME_FILE="$untrusted_hostname_file"
origin="$(vx_harbor_origin_json)" || fail 'valid Vesta origin was rejected'
jq -e '. == {
    HOSTNAME:"panel.example.com", PORT:8083,
    REGISTRY:"panel.example.com:8083", ORIGIN:"https://panel.example.com:8083"
}' <<<"$origin" >/dev/null || fail 'derived origin is incorrect'

for invalid_hostname in localhost panel 127.0.0.1 '[::1]' '-bad.example.com'; do
    printf '%s\n' "$invalid_hostname" >"$hostname_file"
    if vx_harbor_origin_json >/dev/null 2>&1; then
        fail "invalid hostname was accepted: $invalid_hostname"
    fi
done
printf 'other.example.com\n' >"$hostname_file"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'certificate hostname mismatch was accepted'
fi
printf 'panel.example.com\n' >"$hostname_file"
printf 'server { root %s/web; listen 8083 ssl; listen 8083 ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'duplicate same-port TLS listeners were accepted'
fi
printf 'server { root %s/web; listen 0 ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" \
    >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'port zero was accepted'
fi
printf 'server { root %s/web; listen 8083 ssl; listen 8443 ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" \
    >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'multiple TLS ports were accepted'
fi

printf 'server { root %s/web; listen 8083 ssl; }\nserver { root /srv/other; listen 9443 ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'certificate from an unrelated server block was accepted'
fi

printf 'server { root %s/web; listen 8083 ssl; ssl_certificate %s; }\nserver { root %s/web; listen 8083 ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" "$VESTA" "$certificate" \
    >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'ambiguous panel server blocks were accepted'
fi

printf 'server { root %s/web; listen 8083 ssl; ssl_certificate %s; include conf.d/panel.conf; }\n' \
    "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'nginx include ambiguity was accepted'
fi

printf 'server { root %s/web; listen $panel_port ssl; ssl_certificate %s; }\n' \
    "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'variable TLS listener was accepted'
fi

printf 'http {\n  # unrelated listener must not become panel authority\n  server { root /srv/other; listen 9443 ssl; ssl_certificate %s; }\n  server {\n    root\n      %s/web; # panel marker\n    listen\n      8083\n      ssl; # numeric TLS authority\n    ssl_certificate\n      %s; # panel certificate\n  }\n}\n' \
    "$certificate" "$VESTA" "$certificate" >"$VESTA/nginx/conf/nginx.conf"
origin="$(vx_harbor_origin_json)" || fail 'multiline/commented panel config was rejected'
jq -e '.PORT == 8083 and .HOSTNAME == "panel.example.com"' <<<"$origin" >/dev/null \
    || fail 'multiline panel config derived the wrong endpoint'
write_nginx

vx_harbor_audit system provider-prepare succeeded disabled
assert_mode "$root/audit.log" 600
jq -e '.OWNER == "system" and .OPERATION == "provider-prepare"
    and .RESULT == "succeeded" and .REASON == "disabled"
    and (.TIMESTAMP | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' \
    "$root/audit.log" >/dev/null || fail 'audit event is invalid'
if vx_harbor_audit system provider-prepare failed $'secret\nleak'; then
    fail 'multiline audit reason was accepted'
fi
if vx_harbor_audit system provider-prepare failed $'control\tcharacter'; then
    fail 'ASCII control audit reason was accepted'
fi
if vx_harbor_audit system provider-prepare failed $'delete\177character'; then
    fail 'ASCII DEL audit reason was accepted'
fi
reason_256_bytes="$(printf 'é%.0s' {1..128})"
vx_harbor_audit system provider-prepare failed "$reason_256_bytes"
reason_258_bytes="${reason_256_bytes}é"
if vx_harbor_audit system provider-prepare failed "$reason_258_bytes"; then
    fail 'audit reason over 256 UTF-8 bytes was accepted'
fi

# Disabled helpers are statically bounded to local state and validation tools;
# prohibited service/network/package commands must not appear in their source.
if grep -En '(^|[[:space:]/])(docker|systemctl|nginx|curl|apt(-get)?|yum|dnf|firewall-cmd|iptables|nft|host|dig|nslookup)([[:space:]]|$)' \
    "$HARBOR_REPO_ROOT/func/vx/harbor/common.sh" \
    "$HARBOR_REPO_ROOT/func/vx/harbor/audit.sh" \
    "$HARBOR_REPO_ROOT/func/vx/harbor/main.sh"; then
    fail 'disabled provider helper contains a prohibited external command'
fi
vx_harbor_provider_prepare
vx_harbor_provider_mode >/dev/null

printf 'Harbor provider state tests passed.\n'
