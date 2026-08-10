#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

export VESTA="$repo_root"
source "$VESTA/func/domain.sh"

for reserved_name in \
    localhost app.localhost test app.test example app.example \
    invalid app.invalid example.com www.example.com \
    example.net www.example.net example.org www.example.org '*.test'; do
    is_acme_name_reserved "$reserved_name"
done

for public_name in \
    jackpridham.com dev.jackpridham.com vxapp.io registry.vxapp.io; do
    ! is_acme_name_reserved "$public_name"
done

install -d \
    "$test_root/bin" "$test_root/conf" "$test_root/func" \
    "$test_root/data/queue"
install -m 0755 "$repo_root/bin/v-update-sys-queue" \
    "$test_root/bin/v-update-sys-queue"
# The live profile intentionally pins VESTA to /usr/local/vesta. Keep the
# copied command inside this isolated fixture instead.
sed -i 's|^source /etc/profile$|: # profile bypassed by isolated test fixture|' \
    "$test_root/bin/v-update-sys-queue"

cat >"$test_root/func/main.sh" <<'EOF'
check_args() {
    [[ "$1" == "$2" ]] || return 1
}
EOF
cat >"$test_root/conf/vesta.conf" <<EOF
BIN='$test_root/bin'
EOF
cat >"$test_root/data/queue/letsencrypt.pipe" <<EOF
printf 'started\n' >>'$test_root/executions'
sleep 2
EOF

VESTA="$test_root" "$test_root/bin/v-update-sys-queue" letsencrypt &
first_pid=$!
for _ in {1..100}; do
    [[ -s "$test_root/executions" ]] && break
    sleep 0.01
done
[[ -s "$test_root/executions" ]]
VESTA="$test_root" "$test_root/bin/v-update-sys-queue" letsencrypt
wait "$first_pid"
[[ "$(wc -l <"$test_root/executions")" -eq 1 ]]
[[ "$(stat -c '%a' "$test_root/data/queue/letsencrypt.lock")" == 600 ]]

reference_logrotate="$repo_root/install/debian/13/logrotate/vesta"
grep -Fqx '    daily' "$reference_logrotate"
grep -Fqx '    rotate 7' "$reference_logrotate"
grep -Fqx '    maxsize 50M' "$reference_logrotate"
grep -Fqx '    compress' "$reference_logrotate"
grep -Fqx '    delaycompress' "$reference_logrotate"

for logrotate_file in \
    "$repo_root"/install/debian/{7,8,9,10,11,12,13}/logrotate/vesta \
    "$repo_root"/install/ubuntu/{12.04,12.10,13.04,13.10,14.04,14.10}/logrotate/vesta \
    "$repo_root"/install/ubuntu/{15.04,15.10,16.04,16.10,17.04,17.10}/logrotate/vesta \
    "$repo_root"/install/ubuntu/{18.04,18.10}/logrotate/vesta \
    "$repo_root"/install/rhel/{5,6,7}/logrotate/vesta; do
    cmp -s "$reference_logrotate" "$logrotate_file"
done

printf 'Let\x27s Encrypt queue safety tests passed.\n'
