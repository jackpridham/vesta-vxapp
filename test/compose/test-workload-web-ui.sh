#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
action="$repo_root/web/ajax/docker/actions/probe.php"
router="$repo_root/web/ajax/docker/router.php"
index="$repo_root/web/ajax/docker/index.php"
template="$repo_root/web/templates/docker_project_shared.php"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'include($_SERVER['"'"'DOCUMENT_ROOT'"'"']."/ajax/include_authentication_check.php")' "$action" \
  || fail 'probe action does not enforce authenticated AJAX access'
grep -Fq '$myvesta_logged_user' "$action" \
  || fail 'probe action is not bound to the authenticated actor'
grep -Fq "in_array(\$probe, \$selected['WORKLOAD']['PROBES'], true)" "$action" \
  || fail 'probe action does not bind selection to declared names'
grep -Fq "'v-run-docker-project-probe'" "$action" \
  || fail 'probe action does not use the fixed controller command'
if grep -Eiq 'argv|stdout|stderr|secret[^a-z].*value|shell_exec|exec\(' "$action"; then
  fail 'probe action exposes an unsafe execution or output surface'
fi
grep -Fq "'probe'," "$router" \
  || fail 'probe action is not routed through authenticated modal dispatch'
grep -Fq "['WORKLOAD']['PROBES']" "$index" \
  || fail 'probe button is not capability-gated by safe project state'
grep -Fq "['WORKLOAD']['LAST_PROBE_RESULT']" \
  "$repo_root/func/vx/compose/lifecycle.sh" \
  && fail 'list state should attach the bounded result generically, not dereference raw fields'
grep -Fq "vx_compose_pretty_json(\$docker_project['WORKLOAD'])" "$template" \
  || fail 'safe workload state is not visible in the project view'

php -l "$action" >/dev/null
php -l "$router" >/dev/null
php -l "$index" >/dev/null
php -l "$template" >/dev/null
echo 'Compose workload web UI tests passed.'
