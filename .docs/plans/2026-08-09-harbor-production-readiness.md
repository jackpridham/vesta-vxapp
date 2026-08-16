# Harbor Production Readiness Implementation Plan

> **For agentic workers:** Selected workflow: Inline Execution. The user requested same-session implementation and validation; the preferred `superpowers:executing-plans` helper is unavailable, so execute these checked steps directly in order without subagents.

**Goal:** Remove the actionable Harbor production blockers by explicitly deferring provider backups, correcting Vesta panel nginx rollback, and making the canonical ShellCheck gate bounded and fast on constrained hosts.

**Architecture:** Public Harbor backup and restore adapters return stable status 78 without locks, service stops, or authority writes, while dormant recovery primitives remain for issue #2. Provider disable validates and reloads the Vesta panel nginx master through the same helpers as activation. Production ShellCheck performs full local analysis in one bounded process per real source file, then follows the shared Compose graph exactly once with graph-wide extended dataflow disabled.

**Tech Stack:** Bash, ShellCheck 0.11, systemd-run cgroup scopes, PHP, GitHub Issues, repository shell test harnesses.

**Validation evidence (2026-08-09):** Repository issues #2 and #3 record the deferred recovery work and constrained-host ShellCheck correction. `test/harbor/run-focused.sh` passed. `test/compose/run-production-readiness-limited.sh` passed at 50% CPU with dynamic cgroup limits and printed `Compose production-readiness release gate passed.` No live provider, container, site, route, firewall, DNS, or production workload was mutated.

---

### Task 1: Defer Harbor backup and restore without provider mutation

**Files:**
- Modify: `func/vx/harbor/backup.sh`
- Modify: `bin/v-backup-harbor-registry`
- Modify: `bin/v-restore-harbor-registry`
- Modify: `test/harbor/test-backup.sh`

- [x] **Step 1: Add a failing public-boundary test**

Add assertions after the dormant primitive coverage in `test/harbor/test-backup.sh`:

```bash
service_before="$(sha256sum "$service_log")"
authority_before="$(sha256sum "$root/provider.json")"
set +e
vx_harbor_backup >/dev/null 2>&1
backup_status=$?
vx_harbor_restore "$id" validate >/dev/null 2>&1
restore_status=$?
set -e
[[ "$backup_status" == 78 && "$restore_status" == 78 ]] \
    || fail 'disabled backup boundary did not return status 78'
[[ "$(sha256sum "$service_log")" == "$service_before" \
    && "$(sha256sum "$root/provider.json")" == "$authority_before" ]] \
    || fail 'disabled backup boundary mutated service or provider authority'
```

- [x] **Step 2: Run the test and verify the old path fails it**

Run `bash test/harbor/test-backup.sh`.

Expected: fail because backup creation and restore validation still execute.

- [x] **Step 3: Implement the stable deferred boundary**

```bash
VX_HARBOR_BACKUP_DEFERRED=78

vx_harbor_backup() {
    return "$VX_HARBOR_BACKUP_DEFERRED"
}

vx_harbor_restore() {
    return "$VX_HARBOR_BACKUP_DEFERRED"
}
```

Both public adapters print `Harbor provider backup and restore are deferred for this release.` to stderr and exit 78 before invoking recovery logic.

- [x] **Step 4: Verify the boundary**

Run:

```bash
bash -n func/vx/harbor/backup.sh bin/v-backup-harbor-registry bin/v-restore-harbor-registry
bash test/harbor/test-backup.sh
```

Expected: dormant archive checks pass; public backup and restore return 78 without service or authority changes.

### Task 2: Align the current contract and operator guidance

**Files:**
- Modify: `.docs/README.md`
- Modify: `.docs/contracts/harbor-provider.md`
- Modify: `.docs/user-guides/vesta-managed-harbor-operator.md`
- Modify: `.docs/user-guides/vesta-managed-harbor.md`
- Modify: `docs/container-orchestration.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`
- Modify: `web/templates/docker_list_shared.php`
- Modify: `test/harbor/test-doc-contract.sh`

- [x] **Step 1: Change the current release contract**

State these exact behaviors in current contracts and guides:

```text
Harbor provider backup and restore are disabled for the first production release.
Both public commands return status 78 without stopping Harbor or changing provider authority.
Existing ciphertext and provider data are retained.
Recovery-key initialization and re-enablement are tracked in GitHub issue #2.
The accepted first-release workload boundary stores no durable application data outside cache.
```

Historical specifications, plans, audits, and dated validation evidence remain unchanged.

- [x] **Step 2: Make panel status explicit**

Replace the backup-age fragment in `web/templates/docker_list_shared.php` with:

```php
.' · '.__('Provider backup').': '.__('disabled for this release')
```

- [x] **Step 3: Update documentation contract tests**

Require `backup and restore are disabled for the first production release`, `return exit status 78 without stopping Harbor`, and `GitHub issue #2`. Remove assertions that present backup creation and validation as current operator steps.

- [x] **Step 4: Validate documentation and PHP**

```bash
bash test/harbor/test-doc-contract.sh
bash test/test_compose_docs.sh
php -l web/templates/docker_list_shared.php
```

Expected: all commands pass.

### Task 3: Correct Harbor disable to use Vesta panel nginx

**Files:**
- Modify: `func/vx/harbor/disable.sh`
- Modify: `test/harbor/test-disable.sh`

- [x] **Step 1: Add failing ingress remove and restore tests**

Exercise `_vx_harbor_disable_ingress_remove` and `_vx_harbor_disable_restore` without replacing them. Stub only:

```bash
vx_harbor_panel_nginx_test() {
    printf 'test:%s\n' "$1" >>"$nginx_log"
}
vx_harbor_panel_nginx_reload() {
    printf 'reload\n' >>"$nginx_log"
}
```

Assert include removal/restoration, test-before-reload ordering, and absence of `/usr/sbin/nginx` and `reload nginx.service` in `func/vx/harbor/disable.sh`.

- [x] **Step 2: Verify the old implementation fails**

Run `bash test/harbor/test-disable.sh`.

Expected: fail because disable invokes Debian nginx instead of Vesta panel helpers.

- [x] **Step 3: Use shared panel helpers**

Validate the candidate with `vx_harbor_panel_nginx_test "$candidate"`. After installing active or restored files, run:

```bash
vx_harbor_panel_nginx_test "$main" || return 1
vx_harbor_panel_nginx_reload
```

- [x] **Step 4: Verify rollback isolation**

```bash
bash -n func/vx/harbor/disable.sh
bash test/harbor/test-disable.sh
bash test/harbor/test-ingress.sh
```

Expected: all commands pass and only the validated Vesta panel master is reloaded.

### Task 4: Bound and optimize production ShellCheck

**Files:**
- Modify: `test/compose/run-production-shellcheck.sh`
- Modify: `test/compose/test-production-shellcheck.sh`
- Modify: `test/compose/test-production-readiness-limited.sh`
- Modify: `func/vx/compose/images.sh`
- Modify: `func/vx/compose/shell-access.sh`
- Modify: `docs/container-orchestration.md`

- [x] **Step 1: Rewrite the strategy test**

Require each adapter and helper in exactly one local invocation, one additional `-x` graph invocation rooted at `func/vx/compose/main.sh`, `--extended-analysis=false` only on the graph call, and a named failure when a fake call returns status 124.

- [x] **Step 2: Implement bounded analysis**

```bash
local_timeout_seconds=30
graph_timeout_seconds=90

run_shellcheck() {
    local scope="$1" timeout_seconds="$2" status
    shift 2
    printf 'ShellCheck %s\n' "$scope" >&2
    if timeout --signal=TERM --kill-after=5 "$timeout_seconds" \
        shellcheck "$@"; then
        return 0
    fi
    status=$?
    if (( status == 124 || status == 137 )); then
        printf 'FAIL: ShellCheck %s exceeded %ss or its resource limit\n' \
            "$scope" "$timeout_seconds" >&2
    fi
    return "$status"
}
```

Run it once per adapter and helper with normal extended analysis, then once for the graph with `--extended-analysis=false -x -S warning -e SC1091 func/vx/compose/main.sh`.

- [x] **Step 3: Resolve newly visible warnings**

Remove unused `digests` from `func/vx/compose/images.sh`. Use `=''` for empty shell-access locals. Add narrow `# shellcheck disable=SC2034` annotations to the two nameref output assignments because callers consume the dynamic names.

- [x] **Step 4: Document preserved coverage**

Document full local dataflow analysis once per file, one source-resolving graph pass, explicit timeouts, and named error scopes. Link issue #3 for constrained-host performance evidence.

- [x] **Step 5: Run strategy validation**

```bash
bash -n test/compose/run-production-shellcheck.sh func/vx/compose/images.sh func/vx/compose/shell-access.sh
bash test/compose/test-production-shellcheck.sh
test/compose/run-production-readiness-limited.sh
```

Expected: strategy tests pass and real ShellCheck completes without warnings.

### Task 5: Run release validation and commit

**Files:**
- Modify: `.docs/plans/2026-08-09-harbor-production-readiness.md`

- [x] **Step 1: Run focused Harbor validation**

Run `bash test/harbor/run-focused.sh`.

Expected: all Harbor fixture, lifecycle, backup-deferral, nginx, documentation, and panel tests pass.

- [x] **Step 2: Run the constrained canonical gate**

Run `test/compose/run-production-readiness-limited.sh`.

Expected: the unchanged canonical gate completes inside computed cgroup limits and prints `Compose production-readiness release gate passed.`

- [x] **Step 3: Run final checks**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and only intentional production-readiness files are changed.

- [x] **Step 4: Record evidence and commit**

Update this plan with measured evidence and issue links, then run:

```bash
git add AGENTS.md .docs docs DOCKER_ORCHESTRATION_DEPLOYMENT.md bin func test web
git commit -m "fix(harbor): close production readiness blockers"
```

Expected: commit succeeds and the worktree is clean.
