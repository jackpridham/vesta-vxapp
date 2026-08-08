#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

: "${FAKE_DOCKER_LOG:?FAKE_DOCKER_LOG is required}"
: "${FAKE_DOCKER_STATE:?FAKE_DOCKER_STATE is required}"

(( $# <= 64 )) || { printf 'fake-docker: too many arguments\n' >&2; exit 64; }
for argument in "$@"; do
    (( ${#argument} <= 4096 )) || { printf 'fake-docker: argument too long\n' >&2; exit 64; }
done
printf '%q ' "$@" >>"$FAKE_DOCKER_LOG"
printf '\n' >>"$FAKE_DOCKER_LOG"

mkdir -p "$FAKE_DOCKER_STATE"

if [[ "${1:-}" != compose ]]; then
    printf 'fake-docker: unsupported command\n' >&2
    exit 64
fi
shift

project=default
compose_file=compose.yaml
while (( $# )); do
    case "$1" in
        -p|--project-name) project="${2:?missing project name}"; shift 2 ;;
        -f|--file) compose_file="${2:?missing compose file}"; shift 2 ;;
        *) break ;;
    esac
done

case "${1:-}" in
    config)
        [[ -f "$compose_file" ]] || { printf 'compose file not found\n' >&2; exit 1; }
        command cat "$compose_file"
        ;;
    up|start|restart)
        printf 'running\n' >"$FAKE_DOCKER_STATE/$project.service"
        ;;
    down|stop)
        printf 'stopped\n' >"$FAKE_DOCKER_STATE/$project.service"
        ;;
    ps)
        if [[ -f "$FAKE_DOCKER_STATE/$project.service" ]]; then
            command cat "$FAKE_DOCKER_STATE/$project.service"
        else
            printf 'absent\n'
        fi
        ;;
    *)
        printf 'fake-docker: unsupported compose command\n' >&2
        exit 64
        ;;
esac
