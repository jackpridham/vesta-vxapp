#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${FAKE_SYSTEMCTL_LOG:?FAKE_SYSTEMCTL_LOG is required}"
: "${FAKE_SYSTEMCTL_STATE:?FAKE_SYSTEMCTL_STATE is required}"

(( $# <= 32 )) || { printf 'fake-systemctl: too many arguments\n' >&2; exit 64; }
for argument in "$@"; do
    (( ${#argument} <= 4096 )) || { printf 'fake-systemctl: argument too long\n' >&2; exit 64; }
    case "${argument,,}" in
        --password|--password=*|--secret|--secret=*|--token|--token=*|--authorization|--authorization=*|authorization:*)
            printf 'fake-systemctl: secret-bearing argument rejected\n' >&2
            exit 64
            ;;
    esac
done
command_name="${1:-}"
unit="${2:-}"
if [[ "$command_name" != daemon-reload ]]; then
    [[ "$unit" =~ ^[A-Za-z0-9@][A-Za-z0-9@_.-]{0,127}\.(service|target|socket|timer)$ ]] \
        || { printf 'invalid unit\n' >&2; exit 64; }
fi
case "$command_name" in
    daemon-reload) (( $# == 1 )) || exit 64 ;;
    start|restart|stop|enable|disable|is-active|is-enabled|status)
        (( $# == 2 )) || exit 64
        ;;
    *) printf 'fake-systemctl: unsupported command\n' >&2; exit 64 ;;
esac

printf '%q ' "$@" >>"$FAKE_SYSTEMCTL_LOG"
printf '\n' >>"$FAKE_SYSTEMCTL_LOG"
mkdir -p "$FAKE_SYSTEMCTL_STATE"
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
esac
