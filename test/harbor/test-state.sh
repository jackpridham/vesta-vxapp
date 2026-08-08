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

assert_mode() {
    [[ "$(stat -c '%a' "$1")" == "$2" ]] || fail "unexpected mode for $1"
}

vx_harbor_provider_prepare
root="$VESTA/data/harbor"
[[ "$(vx_harbor_root)" == "$root" ]] || fail 'provider root is incorrect'
[[ "$(vx_harbor_data_root)" == /var/lib/vesta-harbor ]] || fail 'data root is incorrect'
for directory in "$root" "$root/owners" "$root/observations" "$root/secrets" \
    "$root/release" "$root/backups" "$root/locks"; do
    [[ -d "$directory" && ! -L "$directory" ]] || fail "missing secure directory: $directory"
    assert_mode "$directory" 700
    [[ "$(stat -c '%u' "$directory")" == "$EUID" ]] \
        || fail "unexpected owner for $directory"
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
    printf 'server {\n    listen 8083 ssl;\n    ssl_certificate %s;\n}\n' "$certificate" \
        >"$VESTA/nginx/conf/nginx.conf"
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
printf 'server {\n    listen 8083 ssl;\n    listen 8083 ssl;\n    ssl_certificate %s;\n}\n' \
    "$certificate" >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'duplicate same-port TLS listeners were accepted'
fi
printf 'server { listen 0 ssl; ssl_certificate %s; }\n' "$certificate" \
    >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'port zero was accepted'
fi
printf 'server { listen 8083 ssl; listen 8443 ssl; ssl_certificate %s; }\n' "$certificate" \
    >"$VESTA/nginx/conf/nginx.conf"
if vx_harbor_origin_json >/dev/null 2>&1; then
    fail 'multiple TLS ports were accepted'
fi
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

# Disabled preparation and mode reads must remain pure state operations. Fixed
# forbidden-command shims make an accidental external mutation fail the test.
shim_dir="$HARBOR_TEST_ROOT/forbidden"
mkdir -p "$shim_dir"
for command in docker systemctl nginx curl apt apt-get yum dnf firewall-cmd \
    iptables nft host dig nslookup; do
    ln -s /bin/false "$shim_dir/$command"
done
PATH="$shim_dir:$PATH" vx_harbor_provider_prepare
PATH="$shim_dir:$PATH" vx_harbor_provider_mode >/dev/null

printf 'Harbor provider state tests passed.\n'
