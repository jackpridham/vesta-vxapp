#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${FAKE_SYSTEMCTL_LOG:?FAKE_SYSTEMCTL_LOG is required}"
: "${FAKE_SYSTEMCTL_STATE:?FAKE_SYSTEMCTL_STATE is required}"

(( $# <= 32 )) || { printf 'fake-systemctl: too many arguments\n' >&2; exit 64; }
for argument in "$@"; do
    (( ${#argument} <= 4096 )) || { printf 'fake-systemctl: argument too long\n' >&2; exit 64; }
done
printf '%q ' "$@" >>"$FAKE_SYSTEMCTL_LOG"
printf '\n' >>"$FAKE_SYSTEMCTL_LOG"

mkdir -p "$FAKE_SYSTEMCTL_STATE"
command_name="${1:-}"
unit="${2:-}"
if [[ "$command_name" != daemon-reload ]]; then
    [[ "$unit" =~ ^[A-Za-z0-9@_.-]+$ ]] || { printf 'invalid unit\n' >&2; exit 64; }
fi
unit_state="$FAKE_SYSTEMCTL_STATE/$unit.state"
unit_enabled="$FAKE_SYSTEMCTL_STATE/$unit.enabled"

case "$command_name" in
    start|restart) printf 'active\n' >"$unit_state" ;;
    stop) printf 'inactive\n' >"$unit_state" ;;
    enable) : >"$unit_enabled" ;;
    disable) rm -f -- "$unit_enabled" ;;
    daemon-reload) [[ -z "$unit" ]] || exit 64 ;;
    is-active)
        [[ -f "$unit_state" ]] && [[ "$(<"$unit_state")" == active ]]
        ;;
    is-enabled) [[ -f "$unit_enabled" ]] ;;
    status)
        if [[ -f "$unit_state" ]]; then command cat "$unit_state"; else printf 'inactive\n'; fi
        ;;
    *) printf 'fake-systemctl: unsupported command\n' >&2; exit 64 ;;
esac
