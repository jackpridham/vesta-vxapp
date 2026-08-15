# SydLocal Cron Backup Compatibility Implementation Plan

> **For agentic workers:** Selected workflow: Inline Execution. These are two
> small compatibility corrections that share one SydLocal acceptance run and
> must be applied in order. The preferred executing-plans helper is unavailable,
> so execute these checked steps directly without subagents. Stop before the
> live backup rerun unless the operator has approved the maintenance window in
> Task 5.

**Goal:** Make SydLocal's weekly **v-backup-users** run complete successfully
and send a clean PHP 8.4 notification while preserving existing Compose
secret, ownership, backup-consistency, and tenant-isolation boundaries.

**Architecture:** Keep cron and **v-backup-users** unchanged. Make the shared
panel bootstrap safe when invoked from Vesta's CLI mail wrapper, then normalize
only two exact authorized representations of a managed secret mount during
Compose runtime verification: the canonical protected source and its current
materialized runtime copy. Reject previous-generation, foreign, writable,
duplicate, and undeclared mounts exactly as before.

**Tech Stack:** Bash, PHP 8.4, Vesta flat-file desired state, Docker inspect
evidence, jq, cron, Exim, Compose shell fixtures, and the repository-owned
resource-limited production-readiness launcher.

---

## Scope, evidence, and safety boundary

This plan addresses two confirmed SydLocal defects:

1. **web/inc/mail-wrapper.php** includes **web/inc/main.php** under bundled PHP
   8.4.11. **main.php** contains deprecated dollar-brace interpolation and
   assumes **REMOTE_ADDR** exists, so the backup notification emits warnings.
2. **asteriskvx/pbx** revision 1 is healthy and correctly labelled, but its
   accepted containers mount secrets from the exact protected
   **pbx/secrets/name** authority. Current runtime preflight expects only
   **pbx/runtime/workload-secrets/current/name**, so backup fails with the
   misleading message “Compose runtime container ownership mismatch”.

The same read-only drift report contains a separate network presentation gap:
the specialized Asterisk profile runs its approved host network while generic
drift projection reports desired **default**. That discrepancy does not cause
the confirmed identity-preflight failure and is outside this correction. Do
not weaken generic network policy or normalize host networking here; retain it
as explicit follow-up evidence.

The August 15 run backed up every other user successfully, failed only
**asteriskvx**, wrote **data/df/backup-error.txt**, and did not write
**data/df/backup-success.txt**.

Do not change cron timing, notification recipients, retention, Asterisk
desired state, container labels, secret files, routes, or service definitions.
Do not recreate Asterisk merely to change its secret source. Do not accept a
source because it shares a prefix: only the canonical file and exact current
runtime-copy file are equivalent. Never print secret contents. Do not use
Docker prune or mutate unrelated containers/sites.

Production and Dev are outside this release. Deploy only to SydLocal
**debian@192.168.100.100** after the complete limited gate passes.

## File responsibility map

- **web/inc/main.php**: safely handles a missing CLI remote address and uses
  PHP 8.4-compatible interpolation.
- **web/inc/i18n.php**: uses PHP's canonical float cast when the shared panel
  bootstrap is compiled by PHP 8.4.
- **test/compose/test-mail-wrapper-php-compatibility.sh**: focused
  compile/runtime guard
  for the CLI mail-wrapper use of **main.php**.
- **func/vx/compose/lifecycle.sh**: treats the canonical protected source and
  current materialized copy as the same logical secret during exact preflight.
- **func/vx/compose/drift.sh**: applies the same normalization to drift evidence.
- **test/compose/test-lifecycle.sh**: fixture covering both accepted secret
  representations and all rejected alternatives.
- **.docs/validation/2026-08-16-sydlocal-cron-backup-compatibility.md**:
  release hashes, tests, installation backup, and redacted acceptance evidence.

## Milestone 1: PHP 8.4-safe backup notifications

### Task 1: Add a focused CLI compatibility test

**Files:**
- Create: **test/compose/test-mail-wrapper-php-compatibility.sh**
- Test: **web/inc/main.php**

- [ ] **Step 1: Create the failing test**

Create **test/compose/test-mail-wrapper-php-compatibility.sh** so the limited
release gate discovers it with the other Compose shell suites:

~~~bash
#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
php_bin=/usr/bin/php
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

compile_output="$("$php_bin" -d error_reporting=-1 -d display_errors=1 \
    -l "$repo_root/web/inc/main.php" 2>&1)" \
    || fail 'main.php did not compile'
grep -Eq 'Deprecated:|Using \$\{' <<<"$compile_output" \
    && fail 'main.php emits deprecated interpolation warnings'

cli_output="$("$php_bin" -d error_reporting=-1 -d display_errors=1 \
    -d session.save_path="$test_root" -r '
        define("NO_AUTH_REQUIRED", true);
        $_SERVER["SCRIPT_FILENAME"] = $argv[1];
        require $argv[1];
    ' "$repo_root/web/inc/main.php" 2>&1)" \
    || fail 'main.php failed in the CLI notification context'
grep -Eq 'Warning:|Deprecated:|Notice:|Undefined array key' <<<"$cli_output" \
    && fail 'main.php emits diagnostics in the CLI notification context'

printf '%s\n' 'Mail-wrapper PHP compatibility tests passed.'
~~~

- [ ] **Step 2: Run the test and verify the current source fails**

~~~bash
bash test/compose/test-mail-wrapper-php-compatibility.sh
~~~

Expected: non-zero with “main.php emits deprecated interpolation warnings”.
The test must not send mail or invoke a backup.

### Task 2: Correct the panel bootstrap without weakening web checks

**Files:**
- Modify: **web/inc/main.php:18**
- Modify: **web/inc/main.php:47**
- Modify: **web/inc/main.php:389**
- Modify: **web/inc/main.php:393**
- Modify: **web/inc/i18n.php:89**
- Test: **test/compose/test-mail-wrapper-php-compatibility.sh**

- [ ] **Step 1: Make the remote address optional only when PHP supplies none**

Replace the initial assignment with:

~~~php
$user_combined_ip = $_SERVER['REMOTE_ADDR'] ?? '';
~~~

Gate the session-hijacking comparison on a server-provided address:

~~~php
if (isset($_SERVER['REMOTE_ADDR'])
    && $_SESSION['user_combined_ip'] != $user_combined_ip
    && $_SERVER['REMOTE_ADDR'] != '127.0.0.1'
    && $SKIP_IP_CHECK == false) {
    session_destroy();
    session_start();
    $_SESSION['request_uri'] = $_SERVER['REQUEST_URI'];
    header("Location: /login/");
    exit;
}
~~~

This skips the IP comparison only where PHP supplies no remote address; normal
panel HTTP requests retain the existing check.

- [ ] **Step 2: Replace deprecated interpolation**

~~~php
$pretty_offset = "UTC{$offset_prefix}{$offset_formatted}";
$timezone_list[$timezone] = "$timezone [ $current_time ] {$pretty_offset}";
~~~

Do not change **mail-wrapper.php** to suppress all errors. Backup failures must
remain observable.

Replace the deprecated alias cast loaded by the same wrapper:

~~~php
$accept_langs_sorted[$code] = (float)$q;
~~~

- [ ] **Step 3: Validate the PHP surface**

~~~bash
php -l web/inc/main.php
php -l web/inc/i18n.php
php -l web/inc/mail-wrapper.php
bash test/compose/test-mail-wrapper-php-compatibility.sh
git diff --check
~~~

Expected: both PHP files report no syntax errors, the focused test passes, and
no whitespace errors are reported.

- [ ] **Step 4: Commit the notification correction**

~~~bash
git add web/inc/main.php web/inc/i18n.php \
    test/compose/test-mail-wrapper-php-compatibility.sh
git commit -m "fix(web): make backup notifications PHP 8.4 safe"
~~~

Expected: normal commit hooks pass without bypasses.

## Milestone 2: Accepted secret-source compatibility

### Task 3: Reproduce the protected-source revision in the lifecycle fixture

**Files:**
- Modify: **test/compose/test-lifecycle.sh:125**
- Modify: **test/compose/test-lifecycle.sh:650**
- Test: **test/compose/test-lifecycle.sh**

- [ ] **Step 1: Let fake Docker select the protected source**

Immediately before the fixture prints the declared credential mount, compute:

~~~bash
secret_source="$(dirname -- "$0")/vesta/data/users/alice/docker-projects/web/runtime/workload-secrets/current/credential"
if [[ -f "$(dirname -- "$0")/secret-mount-authority" ]]; then
    secret_source="$(dirname -- "$0")/vesta/data/users/alice/docker-projects/web/secrets/credential"
fi
printf '"Mounts":[{"Source":"%s","Destination":"/run/secrets/credential","RW":%s}' \
    "$secret_source" "$mount_rw"
~~~

Keep the existing previous-generation, foreign, extra, and writable switches.

- [ ] **Step 2: Add protected-source acceptance assertions**

After the current runtime-copy preflight and drift assertions, add:

~~~bash
touch "$test_root/secret-mount-authority"
[[ "$(vx_compose_runtime_identity_preflight alice web \
        "$project_root/runtime/canonical.json" \
        "$project_root/images.json" 1)" == complete ]] \
    || fail 'accepted protected secret source failed exact preflight'
vx_compose_drift_observe_json alice web | jq -e '
    .MATCH == true
    and .CHANGED_SERVICES == []
    and .DESIRED[0].MOUNTS == .OBSERVED[0].MOUNTS
' >/dev/null || fail 'accepted protected secret source produced false drift'
rm -f -- "$test_root/secret-mount-authority"
~~~

- [ ] **Step 3: Prove the current implementation fails**

~~~bash
bash test/compose/test-lifecycle.sh
~~~

Expected: non-zero with “accepted protected secret source failed exact
preflight”.

### Task 4: Normalize only exact accepted secret sources

**Files:**
- Modify: **func/vx/compose/lifecycle.sh:105**
- Modify: **func/vx/compose/drift.sh:65**
- Test: **test/compose/test-lifecycle.sh**
- Test: **test/compose/test-backup.sh**

- [ ] **Step 1: Normalize current runtime copies during preflight**

In **vx_compose_runtime_identity_preflight**, retain canonical protected source
authority and add a bounded logical name:

~~~jq
[($canonical[0].services[$service].secrets // [])[]
    | . as $secret
    | ($secret.source // $secret) as $name
    | {NAME:$name,
       SOURCE:($canonical[0].secrets[$name].file // ""),
       TARGET:($secret.target // ("/run/secrets/"+$name)),
       READ_ONLY:true}]
| sort_by(.TARGET,.SOURCE)
~~~

For each inspected mount, select the declared secret by exact target and
normalize only the exact current runtime copy:

~~~jq
. as $mount
| ($desired
    | map(select(.TARGET == ($mount.Destination // "")))
    | first) as $want
| {SOURCE:(
        if $want != null
            and ($mount.Source // "")
                == ($root+"/runtime/workload-secrets/current/"+$want.NAME)
        then $want.SOURCE
        else ($mount.Source // "")
        end),
   TARGET:($mount.Destination // ""),
   READ_ONLY:($mount.RW == false)}
~~~

Compare that array with **$desired | map(del(.NAME))**. Do not use a prefix as
authority: only the exact current file above may normalize successfully.

- [ ] **Step 2: Apply identical normalization to drift**

Build desired secret mounts from canonical authority:

~~~jq
if type=="string" then
    {SOURCE:($root.secrets[.].file // ""),
     TARGET:("/run/secrets/"+.),READ_ONLY:true}
else
    {SOURCE:($root.secrets[.source].file // ""),
     TARGET:(.target // ("/run/secrets/"+.source)),READ_ONLY:true}
end
~~~

At the start of **actualmounts($root)**, derive the container service's exact
declared secret records:

~~~jq
. as $container
| [($root.services[
        $container.Config.Labels["com.docker.compose.service"]
    ].secrets // [])[]
    | . as $secret
    | ($secret.source // $secret) as $name
    | {NAME:$name,
       SOURCE:($root.secrets[$name].file // ""),
       TARGET:($secret.target // ("/run/secrets/"+$name))}]
    as $declared_secrets
~~~

For each observed mount, match by exact target. Normalize its source to the
canonical source only when it equals
the exact current runtime-copy expression formed from project root, the fixed
**runtime/workload-secrets/current/** directory, and the declared secret name;
otherwise retain the observed source. Preserve existing named-volume
normalization after this.

- [ ] **Step 3: Run focused syntax and behavior tests**

~~~bash
bash -n func/vx/compose/lifecycle.sh \
    func/vx/compose/drift.sh \
    test/compose/test-lifecycle.sh \
    test/compose/test-backup.sh
shellcheck -x -e SC2004 func/vx/compose/lifecycle.sh \
    func/vx/compose/drift.sh
bash test/compose/test-lifecycle.sh
bash test/compose/test-backup.sh
bash test/compose/test-runtime-secrets.sh
git diff --check
~~~

Expected: all pass. Writable, previous-generation, foreign, extra, duplicate,
and undeclared secret mounts must remain rejected.
The narrow SC2004 exclusion covers the pre-existing arithmetic-array style at
the lifecycle timeout assignment; the constrained release gate remains the
authoritative whole-file ShellCheck run.

- [ ] **Step 4: Commit the Compose correction**

~~~bash
git add func/vx/compose/lifecycle.sh func/vx/compose/drift.sh \
    test/compose/test-lifecycle.sh
git commit -m "fix(compose): preserve accepted secret mount authority"
~~~

Expected: normal commit hooks pass without bypasses.

## Milestone 3: Release validation and SydLocal acceptance

### Task 5: Validate, publish, install, and exercise the corrected path

**Files:**
- Create: **.docs/validation/2026-08-16-sydlocal-cron-backup-compatibility.md**
- Deploy: **/usr/local/vesta/web/inc/main.php**
- Deploy: **/usr/local/vesta/web/inc/i18n.php**
- Deploy: **/usr/local/vesta/func/vx/compose/lifecycle.sh**
- Deploy: **/usr/local/vesta/func/vx/compose/drift.sh**

- [ ] **Step 1: Run the constrained release gate**

~~~bash
test/compose/run-production-readiness-limited.sh
~~~

Expected final line:

~~~text
Compose production-readiness release gate passed.
~~~

Do not run the unlimited gate or broad standalone ShellCheck on SydLocal.

- [ ] **Step 2: Push the exact tested commits**

~~~bash
git status --short --branch
git push origin master
~~~

Expected: clean worktree, synchronized branch, and passing pre-push hooks.

- [ ] **Step 3: Capture pre-install evidence**

~~~bash
ssh debian@192.168.100.100 'sudo env VESTA=/usr/local/vesta bash -s' <<'REMOTE'
set -euo pipefail
systemctl is-active cron docker nginx dovecot exim4
stat -c '%n|%s|%y' /usr/local/vesta/log/backup.log \
    /usr/local/vesta/data/df/backup-error.txt
/usr/local/vesta/bin/v-list-docker-project asteriskvx pbx json \
    | jq -c '{OWNER,PROJECT,PROFILE,STATE,REVISION,HEALTH}'
REMOTE
~~~

Expected: services active; **asteriskvx/pbx** running at revision 1.

- [ ] **Step 4: Install only four runtime files with a backup**

Copy each tested file to its named **/tmp/*.release** path, then:

~~~bash
ssh debian@192.168.100.100 'sudo bash -s' <<'REMOTE'
set -euo pipefail
backup_dir=$(mktemp -d \
    /root/vesta-backups/pre-cron-backup-compatibility.XXXXXXXX)
install -m 0644 /usr/local/vesta/web/inc/main.php "$backup_dir/main.php"
install -m 0644 /usr/local/vesta/web/inc/i18n.php "$backup_dir/i18n.php"
install -m 0644 /usr/local/vesta/func/vx/compose/lifecycle.sh \
    "$backup_dir/lifecycle.sh"
install -m 0644 /usr/local/vesta/func/vx/compose/drift.sh \
    "$backup_dir/drift.sh"
install -o root -g root -m 0644 /tmp/main.php.release \
    /usr/local/vesta/web/inc/main.php
install -o root -g root -m 0644 /tmp/i18n.php.release \
    /usr/local/vesta/web/inc/i18n.php
install -o root -g root -m 0644 /tmp/lifecycle.sh.release \
    /usr/local/vesta/func/vx/compose/lifecycle.sh
install -o root -g root -m 0644 /tmp/drift.sh.release \
    /usr/local/vesta/func/vx/compose/drift.sh
rm -f /tmp/main.php.release /tmp/i18n.php.release \
    /tmp/lifecycle.sh.release /tmp/drift.sh.release
printf 'BACKUP=%s\n' "$backup_dir"
REMOTE
~~~

Do not use archive-mode rsync against **/usr/local/vesta**. These interpreted
files require no service or container restart.

- [ ] **Step 5: Validate installed code before backup**

~~~bash
ssh debian@192.168.100.100 'sudo env VESTA=/usr/local/vesta bash -s' <<'REMOTE'
set -euo pipefail
for file in /usr/local/vesta/web/inc/main.php \
    /usr/local/vesta/web/inc/i18n.php; do
    /usr/local/vesta/php/bin/php -d error_reporting=-1 -d display_errors=1 \
        -l "$file" 2>&1 | tee /tmp/vesta-php-lint.out
    ! grep -Eq 'Deprecated:|Warning:|Notice:' /tmp/vesta-php-lint.out
done
rm -f /tmp/vesta-php-lint.out
user=asteriskvx
source /usr/local/vesta/func/main.sh
source /usr/local/vesta/func/vx/compose/main.sh
test "$(vx_compose_runtime_identity_preflight asteriskvx pbx)" = complete
vx_compose_drift_observe_json asteriskvx pbx | jq -e '
    all(.CHANGED_SERVICES[]?.CHANGES[]?; . != "mount")
' >/dev/null
REMOTE
~~~

Expected: PHP clean, preflight **complete**, and no secret-mount drift. The
known specialized-profile network presentation gap may remain and must be
recorded rather than authorized away. If any required check fails, restore the
four files from the recorded backup and stop before backup execution.

- [ ] **Step 6: Run the single-user backup in an approved window**

The Compose backup contract may briefly quiesce and restart a project:

~~~bash
ssh debian@192.168.100.100 \
    'sudo env VESTA=/usr/local/vesta /usr/local/vesta/bin/v-backup-user asteriskvx'
~~~

Immediately verify:

~~~bash
ssh debian@192.168.100.100 'sudo env VESTA=/usr/local/vesta bash -s' <<'REMOTE'
set -euo pipefail
/usr/local/vesta/bin/v-list-docker-project asteriskvx pbx json \
    | jq -e '.STATE == "running" and .REVISION == 1 and .HEALTH == "healthy"' \
    >/dev/null
/usr/local/vesta/bin/v-list-docker-project-health asteriskvx pbx json \
    | jq -e '.STATUS == "healthy" and .FRESHNESS == "fresh"' >/dev/null
REMOTE
~~~

Expected: backup exits zero and the same revision returns healthy.

- [ ] **Step 7: Exercise the original all-user command**

Still inside the approved window, skip only the optional MySQL repair and keep
the normal backup/notification behavior:

~~~bash
ssh debian@192.168.100.100 'sudo env VESTA=/usr/local/vesta bash -s' <<'REMOTE'
set -euo pipefail
output=$(mktemp /root/v-backup-users-acceptance.XXXXXXXX)
chmod 0600 "$output"
if ! /usr/local/vesta/bin/v-backup-users 0 >"$output" 2>&1; then
    tail -n 40 "$output" >&2
    exit 1
fi
if grep -Eq 'PHP (Deprecated|Warning):|Using \$\{' "$output"; then
    tail -n 40 "$output" >&2
    exit 1
fi
rm -f "$output"
test -f /usr/local/vesta/data/df/backup-success.txt
test ! -e /usr/local/vesta/data/df/backup-error.txt
REMOTE
~~~

Expected: exit zero, no PHP diagnostics, success marker present, error marker
absent, and cron configuration unchanged.

- [ ] **Step 8: Record evidence and commit**

Create the validation document with exact commits and hashes, focused/full
gate results, SydLocal backup directory, pre/post project revision and health,
backup result markers, and confirmation that no secret values, unrelated
workloads, routes, sites, or cron entries changed.

~~~bash
git add .docs/validation/2026-08-16-sydlocal-cron-backup-compatibility.md
git commit -m "docs(validation): record SydLocal backup compatibility"
git push origin master
git status --short --branch
~~~

Expected: hooks pass and the final worktree is clean and synchronized.

## Final acceptance checklist

- [ ] Bundled PHP 8.4 compiles and loads **main.php** in CLI context without
  deprecation, warning, notice, or undefined-key output.
- [ ] HTTP requests retain the remote-address session check.
- [ ] Preflight accepts exact canonical protected secret sources.
- [ ] Preflight accepts exact current materialized secret copies.
- [ ] Foreign, previous-generation, writable, duplicate, extra, and undeclared
  mounts remain rejected.
- [ ] Fixture drift matches for both accepted secret-source representations;
  SydLocal no longer reports **mount** drift for Asterisk.
- [ ] Focused tests and limited production-readiness gate pass.
- [ ] Individual Asterisk backup and **v-backup-users 0** exit zero.
- [ ] **asteriskvx/pbx** remains revision 1, running and healthy.
- [ ] **backup-success.txt** replaces **backup-error.txt**.
- [ ] Cron schedule, retention, notification recipient, sites, routes, and
  unrelated containers remain unchanged.
- [ ] The pre-existing Asterisk host-network drift presentation is recorded as
  separate follow-up and this patch does not broaden network authorization.
