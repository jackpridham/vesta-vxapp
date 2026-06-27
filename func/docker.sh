#!/bin/bash

is_docker_engine_available() {
    command -v docker >/dev/null 2>&1
}

ensure_docker_engine_available() {
    if ! is_docker_engine_available; then
        echo "Error: Docker is not installed"
        exit $E_DISABLED
    fi
}

ensure_docker_container_name_provided() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo "Error: Container name is required"
        exit $E_ARGS
    fi
}

ensure_docker_container_exists() {
    local container_name="$1"

    if ! docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "Error: Container $container_name does not exist"
        exit $E_NOTEXIST
    fi
}
