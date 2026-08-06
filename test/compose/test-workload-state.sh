#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta" HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"
printf '%s\n' "DOCKER_PROJECTS='4'" "DOCKER_SERVICES='8'" "DOCKER_CPUS='4.000'" \
  "DOCKER_MEMORY_MB='4096'" "DOCKER_PIDS='512'" "DOCKER_STORAGE_MB='128'" \
  "DOCKER_PORTS='8'" "DOCKER_SECRETS='8'" "DOCKER_VOLUMES='8'" \
  >"$VESTA/data/users/alice/user.conf"
source "$repo_root/func/vx/compose/main.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

candidate="$test_root/candidate"; mkdir "$candidate"
printf 'services: {}\n' >"$candidate/compose.yaml"
printf '{"name":"vx-alice-app","services":{"service":{"image":"sha256:%064d"}}}\n' 1 >"$candidate/canonical.json"
sha256sum "$candidate/canonical.json" >"$candidate/canonical.sha256"
printf '%s\n' "POLICY_SCHEMA='1'" "VALIDATOR_VERSION='2'" "PROFILE='standard'" \
  "PROFILE_VERSION='2'" "SERVICES='1'" "CPUS_MILLI='0'" "MEMORY_MB='0'" \
  "PIDS='0'" "STORAGE_MB='0'" "PORTS='0'" "SECRETS='0'" "VOLUMES='0'" >"$candidate/policy.conf"
printf '{}\n' >"$candidate/images.json"
printf '{"image":{"id":"sha256:%064d"},"probes":{},"profile":{"name":"standard","version":2},"schema":1,"workload":{"id":"example","release":"one"}}\n' 1 >"$candidate/workload.json"
printf '{"ARCHIVE_SHA256":"%064d","CANONICAL_SHA256":"%064d","WORKLOAD_SHA256":"%064d"}\n' \
  1 2 3 >"$candidate/workload-evidence.json"
printf '%064d  workload.json\n%064d  compose.yaml\n' 3 4 \
  >"$candidate/workload-manifest.sha256"
chmod 0600 "$candidate/workload.json" "$candidate/workload-evidence.json" \
  "$candidate/workload-manifest.sha256"
vx_compose_store_new alice app standard "$candidate"
root="$(vx_compose_project_root alice app)"
vx_compose_active_revision_verify alice app \
  || fail 'accepted workload revision did not verify'
inspect="$(vx_compose_inspect_json alice app)"
jq -e '.WORKLOAD.ID=="example" and .WORKLOAD.RELEASE=="one"
  and .WORKLOAD.PROBES==[] and .WORKLOAD.LAST_PROBE_RESULT==null' \
  <<<"$inspect" >/dev/null || fail 'safe workload inspection is incomplete'
printf '{"image":{"id":"sha256:%064d"},"probes":{},"profile":{"name":"standard","version":2},"schema":1,"workload":{"id":"example","release":"tampered"}}\n' 1 >"$root/workload.json"
chmod 0600 "$root/workload.json"
if vx_compose_active_revision_verify alice app 2>/dev/null; then
  fail 'active workload drift was accepted'
fi
cp "$root/revisions/000001/workload.json" "$root/workload.json"; chmod 0600 "$root/workload.json"

fake_docker="$test_root/docker"
printf '%s\n' '#!/bin/sh' 'case "$1" in ps) exit 0;; esac' >"$fake_docker"; chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"
drift="$(vx_compose_drift_observe_json alice app)"
jq -e '.WORKLOAD.MATCH==true and (.WORKLOAD.CURRENT_SHA256|test("^[a-f0-9]{64}$"))' \
  <<<"$drift" >/dev/null || fail 'workload authority is absent from drift evidence'
printf '{}\n' >"$root/workload-evidence.json"; chmod 0600 "$root/workload-evidence.json"
drift="$(vx_compose_drift_observe_json alice app)"
jq -e '.WORKLOAD.MATCH==false and .MATCH==false' <<<"$drift" >/dev/null \
  || fail 'workload evidence drift was not reported'

echo 'Compose workload state tests passed.'
