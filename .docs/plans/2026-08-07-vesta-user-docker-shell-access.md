# Vesta User Docker Shell Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `$milestone-driven-implementation`. This is one integrated security product:
> authenticated shell access, Vesta package entitlement, revocation, sudo
> installation, and Compose policy must be delivered together. Use fresh
> implementers inside each milestone, run focused tests continuously, and
> perform a security/specification review at every milestone boundary. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow active, SSH-enabled Vesta users with Docker project quota to
manage only their own `standard` Compose projects from a local shell, without
Docker-socket access, caller-selected owner identity, blanket sudo, or manual
group maintenance.

**Architecture:** Vesta package state remains authoritative. Vesta derives
membership in one system group, `vesta-compose-users`, and that group may run
exactly one root-owned broker. The unprivileged `v-docker` client calls the
broker through `sudo`; the broker derives the actor from `SUDO_UID` and the
passwd database, forces owner equal to actor, rechecks live Vesta entitlement
on every invocation, permits only an explicit operation catalog, and delegates
to existing Compose helpers under a clean environment and existing project
locks. Group membership is only a coarse entry gate and never grants access to
Docker's socket or group.

**Tech Stack:** Bash, Vesta flat-file package/user state, sudoers, Linux system
groups, Docker Compose v2, PHP package forms, existing Vesta Compose policy and
transaction helpers, focused Bash/PHP security tests, and disposable root
integration tests.

---

## Scope and security decision

The existing Docker-related `v-*` commands must not be granted directly with
sudo. Many accept caller-controlled `USER`, `OWNER`, or `ACTOR` arguments;
`func/vx/compose/roles.sh` correctly authorizes those semantic identities but
does not authenticate the Unix process that supplied them. A sudo rule such as
`/usr/local/vesta/bin/v-*docker*` would therefore permit cross-owner or
`admin` impersonation.

The durable boundary is:

```text
SSH Vesta user
    |
    | v-docker OPERATION ...
    v
/usr/bin/sudo -n /usr/local/vesta/bin/v-run-user-docker-command ...
    |
    | exact sudo target; root-owned; NOSETENV
    | actor := passwd(SUDO_UID); owner := actor
    | live package/shell/suspension/group/profile checks
    v
existing Vesta Compose commands and helpers
    |
    | deny-first policy, quota, project lock, immutable preview,
    | revision binding, ownership-label validation, redaction
    v
Docker daemon
```

The system group is named `vesta-compose-users`. It is Vesta-owned derived
state. It must never:

- be named `docker` or gain access to `/var/run/docker.sock`;
- own or receive ACLs on Vesta state, project data, secrets, or Docker files;
- receive a wildcard Vesta command, shell, interpreter, editor, copier, or
  arbitrary executable through sudo;
- be treated as sufficient authorization by the broker.

An account is eligible only when all of these facts are true at invocation
time:

```text
real Unix account and Vesta account both exist
AND passwd username/UID/home/shell agree with the Vesta owner
AND actor is not admin or root
AND user.conf is authoritative, regular, non-linked, and not actor-writable
AND SUSPENDED='no'
AND SHELL is an explicitly supported interactive shell (initially bash)
AND effective DOCKER_PROJECTS is a positive integer or unlimited
AND actor is a current member of vesta-compose-users
```

`DOCKER_PROJECTS`, not the presence of a currently running container, is the
entitlement authority. This permits creation of the first project and removes
access when an administrator disables Docker in the user's package. The broker
rechecks these facts after taking the owner access lock, so stale supplementary
group membership in an existing SSH session fails closed immediately.

## Initial user command catalog

Users run `v-docker`; they do not sudo existing `v-*` commands directly. The
client syntax intentionally omits owner, actor, and profile arguments.

| User command | Existing authority invoked with actor/owner injected |
| --- | --- |
| `v-docker projects [FORMAT]` | `v-list-docker-projects OWNER FORMAT` |
| `v-docker show PROJECT [FORMAT]` | `v-list-docker-project OWNER PROJECT FORMAT` |
| `v-docker definition PROJECT [FORMAT]` | `v-list-docker-project-definition OWNER PROJECT FORMAT` |
| `v-docker quota [FORMAT]` | `v-list-docker-compose-quota OWNER FORMAT` |
| `v-docker validate PROJECT [FORMAT]` | `v-validate-docker-project OWNER PROJECT FORMAT` |
| `v-docker health PROJECT [FORMAT]` | `v-list-docker-project-health OWNER PROJECT FORMAT` |
| `v-docker logs PROJECT [SERVICE] [LINES]` | bounded `v-list-docker-project-logs` |
| `v-docker stats PROJECT [PERIOD] [FORMAT]` | `v-list-docker-project-stats` |
| `v-docker alerts PROJECT [FORMAT]` | `v-list-docker-project-alerts` |
| `v-docker operation PROJECT [FORMAT]` | actor-aware operation read |
| `v-docker routes PROJECT [FORMAT]` | owner route read |
| `v-docker backups PROJECT [FORMAT]` | managed backup read |
| `v-docker secrets PROJECT [FORMAT]` | redacted metadata only |
| `v-docker registries [FORMAT]` | redacted metadata only |
| `v-docker drift PROJECT [FORMAT]` | actor-aware drift read |
| `v-docker probe PROJECT PROBE [FORMAT]` | immutable named project probe |
| `v-docker start\|stop\|restart PROJECT` | `v-run-docker-project-action` |
| `v-docker recreate PROJECT [SERVICE]` | `v-run-docker-project-action` |
| `v-docker deploy PROJECT` | deploy accepted desired state |
| `v-docker preview PROJECT add\|change` | forced `standard`; Compose bytes on stdin |
| `v-docker apply PROJECT PREVIEW SOURCE_SHA CANDIDATE_SHA REVISION` | immutable preview apply |
| `v-docker backup PROJECT` | managed backup creation |
| `v-docker restore PROJECT BACKUP_ID validate\|apply` | managed backup ID only |
| `v-docker rollback-preview PROJECT REVISION` | manifest-bound rollback preview |
| `v-docker rollback-apply PROJECT REVISION CURRENT FROM_SHA TO_SHA` | exact rollback apply |
| `v-docker reconcile-preview PROJECT` | deterministic drift preview |
| `v-docker reconcile-apply PROJECT DRIFT_SHA REVISION` | exact reconcile apply |
| `v-docker secret-add\|secret-change PROJECT NAME` | value bytes on stdin |
| `v-docker secret-delete PROJECT NAME` | actor-aware secret deletion |
| `v-docker registry-add\|registry-change REGISTRY USERNAME` | password bytes on stdin |
| `v-docker registry-delete REGISTRY` | owner registry deletion |
| `v-docker route-add PROJECT DOMAIN SERVICE PORT [SCHEME] [PATH]` | owner-domain route mutation |
| `v-docker route-delete PROJECT DOMAIN` | owner-domain route deletion |
| `v-docker alert-ack PROJECT ALERT_ID` | actor-aware acknowledgment |
| `v-docker remove PROJECT keep-data` | retained-data deletion only |

Formats remain the formats supported by each existing command, constrained by
an explicit enum. Log lines remain capped by the existing 2,000-line/1 MiB
boundary. Project, service, probe, registry, secret, revision, digest, domain,
port, period, and backup identifiers are validated before delegation.

Keep these operations administrator-only:

- Docker Engine installation, repair, socket access, raw Docker/Compose, raw
  inspect, arbitrary exec, and global monitoring;
- privileged/admin profile assignment or revocation;
- local image approval/revocation, arbitrary archive/image loading, and image
  pull until per-owner image-layer disk and pull-rate accounting exists;
- protected workload-bundle plan/import;
- existing-runtime adoption and legacy migration;
- arbitrary filesystem-path restore, prune, purge, mount-guard, data-root,
  firewall, or host mutations;
- raw audit access and cross-owner delegated role management.

Named persisted probes are the supported substitute for arbitrary
`docker exec`. Standard projects continue to use immutable registry digests
through the existing trust/policy path; this plan does not weaken image trust
to make shell delivery easier.

## File structure

| File | Responsibility |
| --- | --- |
| `.docs/contracts/compose-shell-access.md` | Stable identity, entitlement, command, input, audit, install, and revocation contract |
| `func/vx/compose/shell-access.sh` | Caller attestation, live eligibility, standard-profile checks, owner access locks, group convergence |
| `func/vx/compose/main.sh` | Source the shell-access helper after storage/quota dependencies |
| `bin/v-docker` | Unprivileged user client that invokes the fixed broker through noninteractive sudo |
| `bin/v-run-user-docker-command` | Sole privileged tenant entry point and explicit operation dispatcher |
| `bin/v-sync-docker-shell-access` | Reconcile one Vesta user's derived group membership |
| `bin/v-sync-docker-shell-access-all` | Repair the complete Vesta-owned group membership set |
| `bin/v-install-docker-shell-access` | Create group, install/validate sudoers atomically, install client path, reconcile users |
| `install/common/sudo/vesta-compose-users` | Canonical single-command sudo policy for all supported platforms |
| `web/inc/vx_compose_package.php` | Canonical PHP list, defaults, validation, and serialization for all Compose quota fields |
| `web/add/package/index.php` | Preserve explicit Compose quota fields when creating packages |
| `web/edit/package/index.php` | Preserve explicit Compose quota fields when editing packages |
| `web/templates/admin/add_package.html` | Administrator inputs for the nine Compose quota dimensions |
| `web/templates/admin/edit_package.html` | Administrator inputs for the nine Compose quota dimensions |
| `func/vx/compose/audit.sh` | Record the authenticated shell actor rather than hard-coded root for broker-mediated owner events |
| `test/compose/test-shell-access.sh` | Identity, entitlement, operation catalog, owner/profile isolation, environment tests |
| `test/compose/test-shell-input.sh` | Bounded stdin, secret redaction, cleanup, injection, and race tests |
| `test/compose/test-shell-access-concurrency.sh` | Revocation/operation ordering and access-lock tests |
| `test/compose/test-shell-access-install.sh` | Group, sudoers, installer, package upgrade, idempotence, rollback tests |
| `test/test_compose_package_form.php` | Package add/edit round-trip for all Compose quota fields |
| `.docs/validation/2026-08-07-compose-shell-access-development.md` | Exact commit, overlay, host-local acceptance, cleanup, and rollback evidence from `192.168.100.100` |

Do not restructure unrelated upstream user/package code. Hooks in existing
commands should remain thin calls into `shell-access.sh`.

---

## Milestone 1: Freeze authority and package entitlement

### Task 1: Publish the shell-access contract and failing surface checks - COMPLETE

**Files:**

- Create: `.docs/contracts/compose-shell-access.md`
- Modify: `.docs/contracts/compose-interfaces.md`
- Modify: `.docs/README.md`
- Modify: `test/test_compose_docs.sh`

- [x] **Step 1: Add failing documentation and CLI-surface assertions**

Add these assertions to the documentation test before creating the new
contract:

```bash
test -f "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'Compose shell-access contract is missing'
grep -Fq 'vesta-compose-users' \
    "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'shell-access contract omits the derived group'
grep -Fq 'v-run-user-docker-command' \
    "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'shell-access contract omits the privileged broker'
```

- [x] **Step 2: Run the assertions and verify the expected failure**

Run:

```bash
bash test/test_compose_docs.sh
```

Expected: failure naming `.docs/contracts/compose-shell-access.md`; no existing
documentation test should fail before the new assertions.

- [x] **Step 3: Write the contract with exact non-negotiable behavior**

The contract must contain these normative statements verbatim or with equally
strict wording:

```text
The Unix caller is authenticated from SUDO_UID plus passwd. ACTOR, OWNER and
PROFILE are never accepted from a tenant command line. For every tenant shell
operation, actor equals owner and the project profile equals standard.

Membership in vesta-compose-users is derived from active Vesta state and is
never sufficient authorization. The broker rechecks identity, suspension,
interactive shell, effective DOCKER_PROJECTS and group membership after
acquiring the owner access lock.

The group grants only v-run-user-docker-command. It grants no Docker socket,
Docker group, Vesta state, shell, interpreter, wildcard command or filesystem
permission.

Compose, secret and registry input is accepted only as bounded stdin and is
snapshotted into root-owned mode-0700/0600 storage. The broker never opens a
tenant-selected filesystem path as root.
```

Include the full command table and administrator-only exclusions from this
plan. Document lock ordering as owner-access lock followed by project lock.

- [x] **Step 4: Index the contract and public client syntax**

Add `compose-shell-access.md` to `.docs/README.md` and add this stable shell
surface to `.docs/contracts/compose-interfaces.md`:

```text
v-docker projects|show|definition|quota|validate|health|logs|stats|alerts ...
v-docker start|stop|restart|recreate|deploy PROJECT ...
v-docker preview PROJECT add|change < compose.yaml
v-docker apply PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
v-docker secret-add|secret-change PROJECT NAME < secret-value
```

- [x] **Step 5: Run documentation checks**

Run:

```bash
bash test/test_compose_docs.sh
git diff --check
```

Expected: PASS.

- [x] **Step 6: Commit the contract milestone**

```bash
git add .docs/contracts/compose-shell-access.md \
  .docs/contracts/compose-interfaces.md .docs/README.md \
  test/test_compose_docs.sh
git commit -m "docs(compose): define tenant shell access contract"
```

#### Closeout Report

- Summary: Published the authenticated, owner-bound shell-access contract and indexed the fixed `v-docker` surface.
- Files changed: `.docs/contracts/compose-shell-access.md`, `.docs/contracts/compose-interfaces.md`, `.docs/README.md`, `test/test_compose_docs.sh`.
- Tests: `bash test/test_compose_docs.sh` PASS; `git diff --check` PASS.
- Commit SHA(s): `d5506f9c2f2bb235ac392e031b2055e85733dd33`.
- Spec review: APPROVED; no blockers.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None; ShellCheck reported only informational SC2016 warnings in test grep assertions.

### Task 2: Make Compose package authority round-trip through the panel - COMPLETE

**Files:**

- Create: `web/inc/vx_compose_package.php`
- Modify: `web/add/package/index.php`
- Modify: `web/edit/package/index.php`
- Modify: `web/templates/admin/add_package.html`
- Modify: `web/templates/admin/edit_package.html`
- Modify: `func/vx/compose/package.sh`
- Create: `test/test_compose_package_form.php`
- Modify: `test/compose/test-package-integration.sh`

- [x] **Step 1: Write a failing PHP round-trip test**

Create a fixture containing all fields and require byte-equivalent values
after add/edit serialization:

```php
$expected = array(
    'DOCKER_PROJECTS' => '3',
    'DOCKER_SERVICES' => '8',
    'DOCKER_CPUS' => '2.500',
    'DOCKER_MEMORY_MB' => '4096',
    'DOCKER_PIDS' => '512',
    'DOCKER_STORAGE_MB' => '8192',
    'DOCKER_PORTS' => '6',
    'DOCKER_SECRETS' => '12',
    'DOCKER_VOLUMES' => '4',
);
if (vx_compose_package_normalize($expected) !== $expected) {
    fwrite(STDERR, "Compose package fields did not round-trip\n");
    exit(1);
}
```

Also assert zero and `unlimited` are accepted, negative values, decimals on
non-CPU fields, more than three CPU decimal places, arrays, shell fragments,
and missing keys are rejected or receive documented defaults.

- [x] **Step 2: Run the PHP test and verify it fails because the helper is absent**

Run:

```bash
php test/test_compose_package_form.php
```

Expected: FAIL because `web/inc/vx_compose_package.php` does not exist.

- [x] **Step 3: Add the focused PHP quota helper**

Implement these complete public functions without shell execution:

```php
function vx_compose_package_fields()
{
    return array(
        'DOCKER_PROJECTS', 'DOCKER_SERVICES', 'DOCKER_CPUS',
        'DOCKER_MEMORY_MB', 'DOCKER_PIDS', 'DOCKER_STORAGE_MB',
        'DOCKER_PORTS', 'DOCKER_SECRETS', 'DOCKER_VOLUMES',
    );
}

function vx_compose_package_normalize($values)
{
    if (!is_array($values)) return false;
    $normalized = array();
    foreach (vx_compose_package_fields() as $field) {
        $value = isset($values[$field]) && !is_array($values[$field])
            ? trim((string) $values[$field]) : '0';
        $pattern = $field === 'DOCKER_CPUS'
            ? '/^(unlimited|[0-9]+(?:\.[0-9]{1,3})?)$/'
            : '/^(unlimited|[0-9]+)$/';
        if (!preg_match($pattern, $value)) return false;
        $normalized[$field] = $value;
    }
    return $normalized;
}

function vx_compose_package_lines($values)
{
    $normalized = vx_compose_package_normalize($values);
    if ($normalized === false) return false;
    $lines = '';
    foreach ($normalized as $field => $value) {
        $lines .= $field."='".$value."'\n";
    }
    return $lines;
}
```

- [x] **Step 4: Wire add/edit controllers and templates**

Use one loop over `vx_compose_package_fields()` to load POST/current values,
validate them before constructing the package, and append exactly one line per
field via `vx_compose_package_lines()`. Add explicit administrator form inputs
for the nine fields. Preserve `DOCKER_CONTAINERS` only as legacy compatibility;
it must not overwrite explicit Compose fields.

- [x] **Step 5: Add the Bash entitlement predicate**

Append this strict helper to `func/vx/compose/package.sh`:

```bash
vx_compose_package_docker_is_enabled() {
    local limit="$1"
    [[ "$limit" == unlimited || "$limit" =~ ^[1-9][0-9]*$ ]]
}
```

Extend `test-package-integration.sh` to cover `0`, positive, `unlimited`,
malformed, and legacy-derived values and to assert package edit surfaces name
every `VX_COMPOSE_PACKAGE_FIELDS` entry.

- [x] **Step 6: Run focused package tests**

Run:

```bash
php -l web/inc/vx_compose_package.php
php -l web/add/package/index.php
php -l web/edit/package/index.php
php test/test_compose_package_form.php
bash test/compose/test-package-integration.sh
git diff --check
```

Expected: PASS.

- [x] **Step 7: Commit package authority preservation**

```bash
git add web/inc/vx_compose_package.php web/add/package/index.php \
  web/edit/package/index.php web/templates/admin/add_package.html \
  web/templates/admin/edit_package.html func/vx/compose/package.sh \
  test/test_compose_package_form.php test/compose/test-package-integration.sh
git commit -m "fix(compose): preserve Docker package entitlement"
```

#### Closeout Report

- Summary: Added validated nine-field Compose package authority, preserved explicit quota values through add/edit forms, and added the positive/unlimited entitlement predicate with legacy compatibility coverage.
- Files changed: `web/inc/vx_compose_package.php`, `web/add/package/index.php`, `web/edit/package/index.php`, `web/templates/admin/add_package.html`, `web/templates/admin/edit_package.html`, `func/vx/compose/package.sh`, `test/test_compose_package_form.php`, `test/compose/test-package-integration.sh`.
- Tests: PHP lint, `php test/test_compose_package_form.php`, `bash test/compose/test-package-integration.sh`, Bash syntax checks, and `git diff --check` PASS.
- Commit SHA(s): `d5506f9c2f2bb235ac392e031b2055e85733dd33`.
- Spec review: APPROVED; no blockers.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None; ShellCheck reported only informational SC2016 warnings in test grep assertions.

### Milestone 1 review gate

- [x] Trace every eligibility field from package template to package file to
  `user.conf` and the new predicate.
- [x] Confirm a package edit cannot silently reset explicit Compose quotas.
- [x] Confirm the contract contains no direct sudo permission for an existing
  Docker `v-*` command.
- [x] Run `git diff --check` and record the milestone commit SHAs in this plan.

Milestone 1 outcome: package templates, controllers, package state/default
helpers, and the documented broker boundary preserve the nine Compose quota
dimensions. Commit `d5506f9c2f2bb235ac392e031b2055e85733dd33` passed the
focused documentation/package tests and independent specification review.
No deferred security or authority findings remain.

---

## Milestone 2: Build the authenticated broker

### Task 3: Implement caller attestation, entitlement, and access locks - COMPLETE

**Files:**

- Create: `func/vx/compose/shell-access.sh`
- Modify: `func/vx/compose/main.sh`
- Create: `test/compose/test-shell-access.sh`

- [x] **Step 1: Write failing identity and entitlement tests**

The test harness must create Vesta fixtures for `alice` and `bob`, fake passwd
records with different UIDs, and a command/Docker canary log. Add assertions
for all of these cases:

```bash
expect_allow alice 1101 bash no 2
expect_allow alice 1101 bash no unlimited
expect_deny alice 1101 bash no 0
expect_deny alice 1101 nologin no 2
expect_deny alice 1101 bash yes 2
expect_deny bob 1101 bash no 2
expect_deny admin 1000 bash no unlimited
expect_deny malformed 1101 bash no '$(touch /tmp/canary)'
```

Also cover missing, linked, actor-writable, malformed, and owner-mismatched
`user.conf`; forged `SUDO_USER`; UID/passwd mismatch; root without sudo caller;
direct non-root invocation; stale manual group membership; and a nonstandard
project. Assert the fake Docker log remains empty after every denial.

- [x] **Step 2: Run the test and verify it fails because the helper is absent**

Run:

```bash
bash test/compose/test-shell-access.sh
```

Expected: FAIL naming `func/vx/compose/shell-access.sh`.

- [x] **Step 3: Implement fixed caller attestation**

Create functions with these exact responsibilities and no `eval`:

```bash
VX_COMPOSE_SHELL_GROUP='vesta-compose-users'
VX_COMPOSE_ACCESS_LOCK_ROOT='/run/lock/vesta-compose-user-access'

vx_compose_shell_actor_resolve() {
    local passwd_record actor _ uid gid _gecos home shell
    [[ "$EUID" -eq 0 && "${SUDO_UID:-}" =~ ^[1-9][0-9]*$
        && "${SUDO_GID:-}" =~ ^[1-9][0-9]*$
        && "${SUDO_USER:-}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    passwd_record="$(getent passwd "$SUDO_UID")" || return 1
    IFS=: read -r actor _ uid gid _gecos home shell <<<"$passwd_record"
    [[ "$actor" == "$SUDO_USER" && "$uid" == "$SUDO_UID"
        && "$actor" != admin && "$actor" != root
        && "$home" == "$HOMEDIR/$actor"
        && "$SUDO_GID" == "$gid" ]] || return 1
    printf '%s\n' "$actor"
}

vx_compose_shell_is_interactive() {
    local shell="$1"
    [[ "$shell" == bash ]]
}

vx_compose_shell_group_contains() {
    id -nG "$1" | tr ' ' '\n' | grep -Fxq "$VX_COMPOSE_SHELL_GROUP"
}
```

Production code must use absolute trusted tool paths or a fixed safe PATH.
Tests may replace functions after sourcing; no production environment variable
may override passwd, group, lock, Vesta, or executable paths.

- [x] **Step 4: Implement live entitlement and standard-profile checks**

Use `vx_compose_meta_get` and
`vx_compose_package_docker_is_enabled`. Verify the authoritative file is a
regular non-link, owned by Vesta authority, and not writable by the actor.
Read `SUSPENDED`, `SHELL`, and `DOCKER_PROJECTS` without sourcing user data.
Add:

```bash
vx_compose_shell_require_eligible() {
    local actor="$1" conf suspended shell limit
    conf="$VESTA/data/users/$actor/user.conf"
    vx_compose_shell_user_conf_is_authoritative "$actor" "$conf" || return 1
    suspended="$(vx_compose_meta_get "$conf" SUSPENDED)" || return 1
    shell="$(vx_compose_meta_get "$conf" SHELL)" || return 1
    limit="$(vx_compose_meta_get "$conf" DOCKER_PROJECTS)" || return 1
    [[ "$suspended" == no ]] || return 1
    vx_compose_shell_is_interactive "$shell" || return 1
    vx_compose_package_docker_is_enabled "$limit" || return 1
    vx_compose_shell_group_contains "$actor" || return 1
}

vx_compose_shell_require_standard_project() {
    local actor="$1" project="$2" root profile
    vx_compose_require_project "$actor" "$project" || return 1
    root="$(vx_compose_project_root "$actor" "$project")"
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || return 1
    [[ "$profile" == standard ]]
}
```

- [x] **Step 5: Add the owner access lock**

Create a root-owned lock directory outside tenant-removable state and acquire
it before the final eligibility check. The API must be:

```bash
vx_compose_shell_access_lock_acquire OWNER
vx_compose_shell_access_lock_release
```

Lock order is always owner-access lock first, existing project lock second.
The broker holds the owner lock for the complete operation. User suspension,
package/shell changes, and deletion take the same owner lock before changing
authority. Reject nesting for a different owner. When spawning an underlying
Vesta command, run it in a subshell that closes only the child's inherited copy
of the access-lock descriptor; the waiting broker process retains its copy and
therefore retains the lock until the complete operation returns.

- [x] **Step 6: Source the helper from the Compose main module**

Add one `source` line after package, quota, storage, and role dependencies are
available. Preserve current public-boundary `VX_COMPOSE_*` cleanup.

- [x] **Step 7: Run the focused identity tests**

Run:

```bash
bash -n func/vx/compose/shell-access.sh func/vx/compose/main.sh \
  test/compose/test-shell-access.sh
bash test/compose/test-shell-access.sh
git diff --check
```

Expected: PASS with an empty Docker canary log for every denied case.

- [x] **Step 8: Commit the authenticated authority helper**

```bash
git add func/vx/compose/shell-access.sh func/vx/compose/main.sh \
  test/compose/test-shell-access.sh
git commit -m "feat(compose): authenticate Docker shell actors"
```

#### Closeout Report

- Summary: Added fixed Unix caller attestation, live package/shell/suspension entitlement, standard-project enforcement, root-owned owner locks, and executable identity/denial coverage.
- Files changed: `func/vx/compose/shell-access.sh`, `func/vx/compose/main.sh`, `test/compose/test-shell-access.sh`.
- Tests: Identity, denial, syntax, ShellCheck, and `git diff --check` PASS.
- Commit SHA(s): `980dbafb`, `bec409d6`, `15184a1e`.
- Spec review: APPROVED after remediation of project authority permissions, transition fail-closed ordering, executable denial/race evidence, and authenticated actor propagation.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None.

### Task 4: Add the fixed read and lifecycle gateway - COMPLETE

**Files:**

- Create: `bin/v-docker`
- Create: `bin/v-run-user-docker-command`
- Modify: `test/compose/test-shell-access.sh`
- Modify: `test/compose/test-cli-surface.sh`
- Modify: `test/compose/test-isolation.sh`
- Modify: `test/compose/test-operator-controls.sh`

- [x] **Step 1: Add failing gateway dispatch tests**

For each initial read and lifecycle verb, assert exact child argv with the
derived actor inserted. Include these representative exact expectations:

```text
projects json -> v-list-docker-projects alice json
show app json -> v-list-docker-project alice app json
start app -> v-run-docker-project-action alice alice app start
recreate app web -> v-run-docker-project-action alice alice app recreate web
probe app ready json -> v-run-docker-project-probe alice alice app ready json
```

Reject unknown actions, option-like values, whitespace/newlines, shell
metacharacters, excessive arguments, invalid formats, lines above 2000,
invalid project/service/probe names, and any attempt to include `alice`,
`bob`, or `admin` as an owner argument. Assert command-substitution and
backtick canaries are not created.

- [x] **Step 2: Run the test and verify the gateway is missing**

Run:

```bash
bash test/compose/test-shell-access.sh
```

Expected: FAIL naming `bin/v-docker` or
`bin/v-run-user-docker-command`.

- [x] **Step 3: Create the unprivileged client**

Use a literal absolute sudo and broker path:

```bash
#!/bin/bash
# info: manage the current Vesta user's Docker Compose projects
# options: OPERATION [ARGUMENTS]
set -Eeuo pipefail
exec /usr/bin/sudo -n -- \
    /usr/local/vesta/bin/v-run-user-docker-command "$@"
```

The client contains no policy, owner argument, environment preservation, or
fallback to raw Vesta/Docker commands.

- [x] **Step 4: Create the broker preamble and clean child runner**

The broker must set `VESTA=/usr/local/vesta`, use a fixed PATH, source only
root-owned Vesta files, resolve the actor, take the owner lock, and recheck
eligibility. Child execution must have this shape:

```bash
run_vesta_user_command() {
    local command="$1"
    shift
    [[ "$command" =~ ^v-[a-z0-9-]+$
        && -x "/usr/local/vesta/bin/$command" ]] || return 1
    (
        vx_compose_shell_access_lock_close_child_copy
        env -i \
            VESTA=/usr/local/vesta \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            HOME=/root USER=root LOGNAME=root LANG=C.UTF-8 \
            "/usr/local/vesta/bin/$command" "$@"
    )
}
```

Do not permit the caller to supply `command`; only literal case branches call
this function. Before sourcing Bash, sudoers must remove `BASH_ENV`, `ENV`,
`SHELLOPTS`, `BASHOPTS`, `CDPATH`, `GLOBIGNORE`, `LD_*`, `PYTHON*`,
`DOCKER_*`, `COMPOSE_*`, `VESTA`, and `VX_COMPOSE_*`.

- [x] **Step 5: Implement the explicit operation switch**

Use `case "$operation"` and arrays. Each branch validates exact argument
count and enums, calls `vx_compose_shell_require_standard_project` for a
project, and invokes one fixed command. The lifecycle branches must be exactly:

```bash
start|stop|restart)
    require_project_only "$@"
    run_vesta_user_command v-run-docker-project-action \
        "$actor" "$actor" "$1" "$operation"
    ;;
recreate)
    require_project_optional_service "$@"
    run_vesta_user_command v-run-docker-project-action \
        "$actor" "$actor" "$1" recreate "${2:-}"
    ;;
deploy)
    require_project_only "$@"
    run_vesta_user_command v-run-docker-project-action \
        "$actor" "$actor" "$1" deploy
    ;;
probe)
    require_probe_args "$@"
    run_vesta_user_command v-run-docker-project-probe \
        "$actor" "$actor" "$1" "$2" "${3:-json}"
    ;;
*)
    fail 'unsupported Docker self-service operation'
    ;;
esac
```

Implement the read branches from the command catalog with the same literal
mapping and derived owner. No branch may concatenate a command line or use
`eval`, `bash -c`, `sh -c`, `sudo`, or a caller path.

- [x] **Step 6: Add authenticated bounded audit events**

Record actor, operation, owner, project when present, result, and timestamp.
Do not record raw arguments, stdin, registry usernames, domain headers,
Docker errors, or secret values. Existing project operations retain their
normal project audit; the broker access event proves the Unix actor.

- [x] **Step 7: Run gateway and existing isolation tests**

Run:

```bash
bash -n bin/v-docker bin/v-run-user-docker-command \
  func/vx/compose/shell-access.sh test/compose/test-shell-access.sh
bash test/compose/test-shell-access.sh
bash test/compose/test-isolation.sh
bash test/compose/test-operator-controls.sh
bash test/compose/test-cli-surface.sh
git diff --check
```

Expected: PASS. Every denied broker request must leave the fake Docker log
empty.

- [x] **Step 8: Commit the read/lifecycle shell surface**

```bash
git add bin/v-docker bin/v-run-user-docker-command \
  test/compose/test-shell-access.sh test/compose/test-cli-surface.sh \
  test/compose/test-isolation.sh test/compose/test-operator-controls.sh
git commit -m "feat(compose): add owner-bound Docker shell gateway"
```

#### Closeout Report

- Summary: Added the unprivileged `v-docker` client, fixed root broker, literal owner-bound read/lifecycle catalog, clean child environment, bounded validation, and authenticated broker audit coverage.
- Files changed: `bin/v-docker`, `bin/v-run-user-docker-command`, `test/compose/test-shell-access.sh`, `test/compose/test-cli-surface.sh`, `test/compose/test-isolation.sh`, `test/compose/test-operator-controls.sh`.
- Tests: Gateway, isolation, operator-control, CLI-surface, syntax, ShellCheck, and `git diff --check` PASS.
- Commit SHA(s): `980dbafb`, `bec409d6`, `15184a1e`.
- Spec review: APPROVED after authenticated FD actor-context remediation.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: Real sudoers/disposable-host validation is assigned to Milestone 3 Task 9.

### Task 5: Add protected stdin and immutable mutation flows - COMPLETE

**Files:**

- Modify: `bin/v-run-user-docker-command`
- Modify: `func/vx/compose/shell-access.sh`
- Create: `test/compose/test-shell-input.sh`
- Modify: `test/compose/test-preview-apply.sh`
- Modify: `test/compose/test-secrets.sh`
- Modify: `test/compose/test-registry.sh`
- Modify: `test/compose/test-redaction.sh`

- [x] **Step 1: Write failing bounded-input and redaction tests**

Test Compose stdin at empty, one byte, exactly 1,048,576 bytes, and 1,048,577
bytes. Test secrets/registry passwords at their contracted limits. Assert the
snapshot parent is root-owned mode `0700`, the file is a regular non-link mode
`0600`, and cleanup occurs on success, validation failure, child failure,
`INT`, and `TERM`.

Feed a unique secret canary and assert it is absent from:

```text
argv
/proc/<pid>/cmdline
environment
stdout/stderr
Vesta history/event log
Compose audit
broker audit
sudo policy/logging configuration
```

Assert no operation accepts a source, secret, password, archive, checksum, or
restore filesystem path.

- [x] **Step 2: Run the input test and verify it fails**

Run:

```bash
bash test/compose/test-shell-input.sh
```

Expected: FAIL because protected stdin snapshotting is absent.

- [x] **Step 3: Implement root-owned bounded stdin snapshots**

Add one helper used by Compose, secret, and registry input:

```bash
vx_compose_shell_snapshot_stdin() {
    local kind="$1" max_bytes="$2" root file bytes
    [[ "$kind" =~ ^(compose|secret|registry)$
        && "$max_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    root="$(mktemp -d /var/tmp/vesta-compose-shell.XXXXXXXX)" || return 1
    chmod 0700 "$root" || { rmdir "$root"; return 1; }
    file="$root/$kind.input"
    umask 077
    head -c "$((max_bytes + 1))" >"$file" || {
        find "$root" -xdev -depth -delete
        return 1
    }
    bytes="$(stat -c %s "$file")" || return 1
    [[ "$bytes" -gt 0 && "$bytes" -le "$max_bytes"
        && ! -L "$file"
        && "$(stat -c '%u:%g:%a:%F' "$root")" == '0:0:700:directory'
        && "$(stat -c '%u:%g:%a:%F' "$file")" == '0:0:600:regular file' ]] \
        || { find "$root" -xdev -depth -delete; return 1; }
    printf '%s\n' "$file"
}
```

The broker owns a trap that deletes only the exact validated snapshot root.
Do not use a caller path, follow links, accept FIFOs, or echo input.

- [x] **Step 4: Wire immutable preview/apply**

`v-docker preview PROJECT add|change < compose.yaml` must snapshot stdin,
force `standard`, and call:

```bash
run_vesta_user_command v-stage-docker-project-preview \
    "$actor" "$actor" "$project" "$snapshot" standard "$mode"
```

`apply` accepts only project, 32-lowercase-hex preview ID, two
64-lowercase-hex digests, and a nonnegative expected revision, then injects
actor/owner into `v-apply-docker-project-preview`. Keep the existing immutable
preview manifest, expiry, revision, route-impact, and project-lock checks.

- [x] **Step 5: Wire secret and registry mutations through stdin**

For secret add/change, snapshot the value and call the actor-aware action
adapter with the derived owner. Secret delete accepts no stdin or extra value.
For registry add/change, add a thin actor-aware adapter if the current command
cannot preserve authenticated actor audit, but keep the existing owner registry
validation and Docker-config isolation. Registry delete accepts only the
validated registry name.

- [x] **Step 6: Wire retained-data deletion, managed restore, rollback, and reconcile**

Implement only these safe forms:

```text
remove PROJECT keep-data
restore PROJECT BACKUP_ID validate|apply
rollback-preview PROJECT REVISION
rollback-apply PROJECT REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA
reconcile-preview PROJECT
reconcile-apply PROJECT DRIFT_SHA CURRENT_REVISION
```

Resolve `BACKUP_ID` with the existing managed backup resolver. Never accept an
archive path. Reuse the existing manifest/digest/revision-bound commands;
never replace them with a direct rollback or Compose invocation.

- [x] **Step 7: Run input, preview, secret, registry, and redaction tests**

Run:

```bash
bash -n bin/v-run-user-docker-command func/vx/compose/shell-access.sh \
  test/compose/test-shell-input.sh
bash test/compose/test-shell-input.sh
bash test/compose/test-preview-apply.sh
bash test/compose/test-secrets.sh
bash test/compose/test-registry.sh
bash test/compose/test-redaction.sh
bash test/compose/test-managed-directory-symlinks.sh
git diff --check
```

Expected: PASS with no secret canary in any output or audit surface.

- [x] **Step 8: Commit protected self-service mutation**

```bash
git add bin/v-run-user-docker-command func/vx/compose/shell-access.sh \
  test/compose/test-shell-input.sh test/compose/test-preview-apply.sh \
  test/compose/test-secrets.sh test/compose/test-registry.sh \
  test/compose/test-redaction.sh
git commit -m "feat(compose): protect Docker shell mutation inputs"
```

#### Closeout Report

- Summary: Added bounded root-owned stdin snapshots and owner-bound immutable preview/apply, secret, registry, backup, rollback, reconcile, and retained-data mutation paths with cleanup/redaction coverage.
- Files changed: `bin/v-run-user-docker-command`, `func/vx/compose/shell-access.sh`, `test/compose/test-shell-input.sh`, and affected preview/secret/registry/redaction tests.
- Tests: Input, preview/apply, secrets, registry, redaction, managed-directory symlink, syntax, ShellCheck, and `git diff --check` PASS.
- Commit SHA(s): `980dbafb`, `bec409d6`, `15184a1e`.
- Spec review: APPROVED; no remaining input or mutation-boundary blockers.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None.

#### Post-acceptance compatibility remediation closeout

- Summary: Aligned brokered Compose stdin with the existing immutable web
  source contract by creating
  `/tmp/vx-compose-web.<32 lowercase hex>/compose.yaml`, while retaining the
  generic protected snapshot shape for secret and registry input. Refactored
  snapshot output into the broker shell so `INT`/`TERM` cleanup knows the
  active root before a blocking read, and preserved the caller umask.
- Files changed: `bin/v-run-user-docker-command`,
  `func/vx/compose/shell-access.sh`, `test/compose/test-shell-input.sh`, and
  `test/compose/fixtures/shell-broker-namespace.sh`.
- Tests: Bash syntax; shell input as the ordinary caller and in a root-mapped
  namespace; executable broker and reconciliation fixtures; immutable preview
  stage/apply; and `git diff --check` PASS. Signal tests cover blocked uploads
  interrupted by both `INT` and `TERM`, and cleanup is covered whether the
  downstream staging adapter consumes the source or leaves it for the broker.
- Commit SHA(s): `bd901e03`, `727f4864`.
- Spec review: APPROVED after the output-variable and signal-cleanup changes.
- Code quality review: APPROVED after cancellation cleanup and caller-umask
  preservation remediation.
- Follow-ups or concerns: Rerun the constrained release gate and repeat exact
  development-host acceptance from the clean rollback baseline.

### Task 6: Bind audit identity and revocation ordering - COMPLETE

**Files:**

- Modify: `func/vx/compose/audit.sh`
- Modify: `bin/v-suspend-user`
- Modify: `bin/v-unsuspend-user`
- Modify: `bin/v-change-user-package`
- Modify: `bin/v-change-user-shell`
- Modify: `bin/v-delete-user`
- Create: `test/compose/test-shell-access-concurrency.sh`
- Modify: `test/compose/test-owner-lifecycle.sh`

- [x] **Step 1: Write failing race and audit tests**

Use controllable FIFOs in fake underlying actions to prove:

- suspension waits for an already-authorized operation to reach a consistent
  terminal state, then records `SUSPENDED=yes`, revokes membership, and stops
  projects before releasing the owner lock;
- a start arriving after suspension begins cannot pass the final eligibility
  check;
- package or shell revocation cannot race a newly authorized action;
- an operation started after revocation never reaches Docker;
- project operations retain existing project-lock serialization;
- a gateway action audit records `ACTOR=alice`, never `root`, `admin`, or a
  caller-supplied value.

- [x] **Step 2: Run the concurrency test and verify it fails**

Run:

```bash
bash test/compose/test-shell-access-concurrency.sh
```

Expected: FAIL because lifecycle commands do not yet coordinate with the owner
access lock.

- [x] **Step 3: Make the audit actor explicit and validated**

Change `vx_compose_owner_audit OWNER ACTION RESULT DETAILS` to accept an
optional fifth actor, validate it as `admin`, `root`, or an active Vesta actor,
and emit that actor. Existing callers default to `root`; every broker-mediated
route, registry, backup-policy, notification, and delete action passes the
authenticated actor explicitly. Never infer actor from `USER` or environment
inside audit code.

- [x] **Step 4: Put authority transitions under the owner access lock**

Use this sequence for suspension/package disable/shell disable/deletion:

```text
acquire owner access lock
persist or establish the denying authority state
remove derived group membership
perform the existing workload/account transition
write bounded audit/history
release owner access lock
```

Use this sequence for enable/unsuspend:

```text
acquire owner access lock
complete existing account/workload restoration
persist active package/shell/suspension state
re-evaluate entitlement and add membership only if eligible
release owner access lock
```

If an existing command cannot safely move state persistence earlier, add a
root-owned transient deny marker under the access-lock root and make the broker
reject it until the command commits or rolls back. Do not leave a window where
the account is logically suspended but can restart its project.

- [x] **Step 5: Run concurrency and lifecycle tests**

Run:

```bash
bash -n func/vx/compose/audit.sh bin/v-suspend-user \
  bin/v-unsuspend-user bin/v-change-user-package bin/v-change-user-shell \
  bin/v-delete-user test/compose/test-shell-access-concurrency.sh
bash test/compose/test-shell-access-concurrency.sh
bash test/compose/test-owner-lifecycle.sh
bash test/compose/test-shell-access.sh
git diff --check
```

Expected: PASS without a deadlock or nested lock-target mismatch.

- [x] **Step 6: Commit audit and revocation ordering**

```bash
git add func/vx/compose/audit.sh bin/v-suspend-user \
  bin/v-unsuspend-user bin/v-change-user-package bin/v-change-user-shell \
  bin/v-delete-user test/compose/test-shell-access-concurrency.sh \
  test/compose/test-owner-lifecycle.sh
git commit -m "fix(compose): serialize Docker shell revocation"
```

#### Closeout Report

- Summary: Bound audit identity to the authenticated broker actor and serialized suspension, package, shell, unsuspend, and deletion transitions through owner access locks and fail-closed deny markers.
- Files changed: `func/vx/compose/audit.sh`, lifecycle commands, `test/compose/test-shell-access-concurrency.sh`, and `test/compose/test-owner-lifecycle.sh`.
- Tests: Concurrency, owner lifecycle, shell access, affected existing Compose suites, syntax, ShellCheck, and `git diff --check` PASS.
- Commit SHA(s): `980dbafb`, `bec409d6`, `15184a1e`.
- Spec review: APPROVED after two focused remediation rounds; authenticated FD context, executable race evidence, and revocation ordering passed.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None.

### Milestone 2 security review gate - COMPLETE

- [x] Review caller attestation, environment construction, operation mapping,
  input snapshots, audit actor, and lock order as one privilege boundary.
- [x] Prove every rejected identity/profile/input case occurs before the fake
  Docker invocation.
- [x] Search for forbidden dispatch patterns:

```bash
rg -n 'eval|bash -c|sh -c|docker.sock|usermod.*docker|vesta/bin/[*]' \
  bin/v-docker bin/v-run-user-docker-command \
  func/vx/compose/shell-access.sh
```

Expected: no dynamic shell dispatch, Docker group/socket permission, or Vesta
wildcard.
- [x] Record milestone commit SHAs and security-review findings in this plan.

Milestone 2 outcome: the authenticated broker, explicit operation catalog,
protected stdin mutation flows, authenticated audit context, and revocation
ordering are implemented and independently specification-approved. Commits
`980dbafb`, `bec409d6`, and `15184a1e` passed the focused security suite.
The only initial findings were corrected before approval; real sudoers and
disposable-host acceptance remains in Milestone 3 Task 9.

---

## Milestone 3: Automate entitlement and installation

### Task 7: Reconcile group membership from Vesta lifecycle state - COMPLETE

**Files:**

- Create: `bin/v-sync-docker-shell-access`
- Create: `bin/v-sync-docker-shell-access-all`
- Modify: `func/vx/compose/shell-access.sh`
- Modify: `bin/v-add-user`
- Modify: `bin/v-change-user-package`
- Modify: `bin/v-update-user-package`
- Modify: `bin/v-change-user-shell`
- Modify: `bin/v-suspend-user`
- Modify: `bin/v-unsuspend-user`
- Modify: `bin/v-rebuild-user`
- Modify: `bin/v-delete-user`
- Modify: `test/compose/test-owner-lifecycle.sh`
- Modify: `test/compose/test-package-integration.sh`

- [x] **Step 1: Add failing membership reconciliation tests**

Use fake `getent`, `groupadd`, `usermod`, `gpasswd`, and `id` functions. Cover:

```text
new eligible Bash user -> added once
zero quota -> absent
positive or unlimited quota -> present
forced package downgrade to zero -> removed
bash to nologin/rssh -> removed
nologin to bash -> added
suspended -> removed before workload suspension
unsuspended -> added only after restoration succeeds
deleted -> removed before userdel
same username with a new UID -> stale identity denied
unknown/manual member -> removed by full reconciliation
repeated synchronization -> no changes and exit 0
```

Assert no test command names or modifies the `docker` group.

- [x] **Step 2: Run lifecycle tests and verify they fail**

Run:

```bash
bash test/compose/test-owner-lifecycle.sh
bash test/compose/test-package-integration.sh
```

Expected: FAIL because synchronization commands/hooks are absent.

- [x] **Step 3: Implement one-user reconciliation**

`v-sync-docker-shell-access USER` validates the Vesta username, takes the owner
access lock, computes eligibility without trusting current group membership,
and converges membership using fixed system tools:

```bash
if vx_compose_shell_should_be_group_member "$user"; then
    /usr/sbin/usermod -a -G vesta-compose-users -- "$user"
else
    /usr/bin/gpasswd -d "$user" vesta-compose-users >/dev/null 2>&1 || :
fi
```

The helper must distinguish an already-absent member from a system error and
must never rewrite `/etc/group` directly.

- [x] **Step 4: Implement full reconciliation**

`v-sync-docker-shell-access-all` takes a global reconciliation lock, enumerates
regular Vesta `user.conf` files, syncs every valid non-admin Vesta account,
then removes members of the dedicated Vesta-owned group that no longer map to
an eligible Vesta account. Emit only bounded added/removed/unchanged/failed
counts; do not print emails, homes, package contents, or secrets.

- [x] **Step 5: Add thin lifecycle hooks**

Call the one-user sync at these committed-state boundaries:

```text
v-add-user: after user.conf is protected
v-change-user-package: after package and Unix shell commit
v-update-user-package: covered through v-change-user-package; full test proves it
v-change-user-shell: after passwd and user.conf agree
v-suspend-user: deny/revoke under owner lock before stopping workloads
v-unsuspend-user: after successful restore and SUSPENDED=no
v-rebuild-user: after successful rebuild
v-delete-user: revoke under owner lock before userdel/removing state
```

Any sync failure aborts an enabling transition before reporting success. A
revocation failure leaves the broker fail-closed through its live authority
check and returns a nonzero administrator-visible result.

- [x] **Step 6: Run lifecycle and package integration tests**

Run:

```bash
bash -n bin/v-sync-docker-shell-access \
  bin/v-sync-docker-shell-access-all func/vx/compose/shell-access.sh \
  bin/v-add-user bin/v-change-user-package bin/v-update-user-package \
  bin/v-change-user-shell bin/v-suspend-user bin/v-unsuspend-user \
  bin/v-rebuild-user bin/v-delete-user
bash test/compose/test-owner-lifecycle.sh
bash test/compose/test-package-integration.sh
bash test/compose/test-shell-access-concurrency.sh
git diff --check
```

Expected: PASS.

- [x] **Step 7: Commit automatic membership lifecycle**

```bash
git add bin/v-sync-docker-shell-access \
  bin/v-sync-docker-shell-access-all func/vx/compose/shell-access.sh \
  bin/v-add-user bin/v-change-user-package bin/v-update-user-package \
  bin/v-change-user-shell bin/v-suspend-user bin/v-unsuspend-user \
  bin/v-rebuild-user bin/v-delete-user \
  test/compose/test-owner-lifecycle.sh \
  test/compose/test-package-integration.sh
git commit -m "feat(compose): reconcile Docker shell entitlement"
```

#### Closeout Report

- Summary: Added one-user and full Vesta-owned group reconciliation with three-state lookup/error handling, stale/manual-member removal, owner/global locks, bounded reporting, and lifecycle hooks at committed authority boundaries.
- Files changed: `bin/v-sync-docker-shell-access`, `bin/v-sync-docker-shell-access-all`, `func/vx/compose/shell-access.sh`, lifecycle/package commands, and owner/package integration tests.
- Tests: Membership, owner lifecycle, package integration, shell concurrency, syntax, failure matrices, and `git diff --check` PASS.
- Commit SHA(s): `e80485ca`, `309bf712`.
- Spec review: APPROVED after reconciliation error-state, stale-member, and executable failure-matrix remediation.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: None.

### Task 8: Install the group and exact sudo policy on every lifecycle path - COMPLETE

**Files:**

- Create: `install/common/sudo/vesta-compose-users`
- Create: `bin/v-install-docker-shell-access`
- Create: `test/compose/test-shell-access-install.sh`
- Modify: `bin/v-install-docker-service`
- Modify: `install/vst-install-debian.sh`
- Modify: `install/vst-install-ubuntu.sh`
- Modify: `install/vst-install-rhel.sh`
- Modify: `install/vst-install-amazon.sh`
- Modify: `src/deb/vesta/postinst`
- Modify: `src/rpm/specs/vesta.spec`
- Create: `example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users`
- Modify: `test/compose/test-package-integration.sh`

- [x] **Step 1: Write failing sudo/install tests**

Assert:

- the group is created with `groupadd --system` and no fixed GID;
- only the exact broker is authorized as root;
- the policy contains `NOPASSWD` and `NOSETENV` plus a fixed secure path;
- the policy contains no Vesta wildcard, Docker command/socket/group, shell,
  interpreter, editor, copier, `SETENV`, or sudo input logging;
- `visudo -cf` passes;
- installation stages a root-owned regular file, validates before rename, and
  installs mode `0440` atomically;
- a linked/untrusted source or target and an invalid staged policy leave the
  previous valid policy untouched;
- repeated installation is byte-stable;
- all fresh installers, Debian postinst, RPM post, and Docker installer invoke
  the installer command;
- package upgrade reconciles existing users;
- no unrelated sudoers file or system group changes.

- [x] **Step 2: Run the install test and verify it fails**

Run:

```bash
bash test/compose/test-shell-access-install.sh
```

Expected: FAIL because the template and installer are absent.

- [x] **Step 3: Create the canonical sudo policy**

Use this exact narrow shape, adjusting only syntax required by the installed
sudo version after `visudo` verification:

```sudoers
# Managed by Vesta. Local edits are replaced by reconciliation.
Defaults:%vesta-compose-users env_reset
Defaults:%vesta-compose-users !setenv
Defaults:%vesta-compose-users secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Defaults:%vesta-compose-users env_keep -= "VESTA BASH_ENV ENV CDPATH GLOBIGNORE BASHOPTS SHELLOPTS PYTHONPATH PYTHONHOME LD_PRELOAD LD_LIBRARY_PATH DOCKER_HOST DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME", env_delete += "VESTA BASH_ENV ENV CDPATH GLOBIGNORE BASHOPTS SHELLOPTS PYTHONPATH PYTHONHOME LD_PRELOAD LD_LIBRARY_PATH DOCKER_HOST DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME"
%vesta-compose-users ALL=(root) NOPASSWD:NOSETENV: /usr/local/vesta/bin/v-run-user-docker-command *
```

Do not enable `log_input`; secret and registry values are supplied on stdin.
Do not grant the client, because only the broker is the privileged boundary.

- [x] **Step 4: Implement atomic installation and repair**

`v-install-docker-shell-access [defer]` must:

1. require root;
2. create `vesta-compose-users` with `groupadd --system` if absent;
3. verify an existing group is a normal local system group;
4. verify the source template and broker are root-owned regular non-links;
5. create a root-owned temporary file inside `/etc/sudoers.d`;
6. copy the template, set `0440`, and run `/usr/sbin/visudo -cf TEMP`;
7. atomically rename it to `/etc/sudoers.d/vesta-compose-users`;
8. install a root-owned `/usr/local/bin/v-docker` symlink or wrapper pointing
   only to `/usr/local/vesta/bin/v-docker`;
9. run full reconciliation unless `defer` is used before Vesta user state
   exists;
10. verify final group, policy, broker, client, and membership state.

On validation failure, remove only the temporary file and preserve the prior
policy.

- [x] **Step 5: Wire fresh install, package upgrade, and Docker installation**

Call `v-install-docker-shell-access defer` in `src/deb/vesta/postinst` before
the fresh-package early exit. Call the normal form during upgrades, after the
fresh installer creates `admin`, in all four supported installer families,
from the RPM post section, and at the end of
`v-install-docker-service`. The normal form must repair group/sudoers drift and
reconcile all existing users.

- [x] **Step 6: Add the synthetic-root sudo policy**

Mirror the canonical sudoers file at
`example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users`. Do not mirror
dynamic `/etc/group` membership; it is host state derived by reconciliation.

- [x] **Step 7: Run sudo/install/package tests**

Run:

```bash
bash -n bin/v-install-docker-shell-access bin/v-install-docker-service \
  install/vst-install-debian.sh install/vst-install-ubuntu.sh \
  install/vst-install-rhel.sh install/vst-install-amazon.sh \
  src/deb/vesta/postinst test/compose/test-shell-access-install.sh
bash test/compose/test-shell-access-install.sh
bash test/compose/test-package-integration.sh
cmp install/common/sudo/vesta-compose-users \
  example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users
git diff --check
```

Expected: PASS. If `visudo` is unavailable in the development environment,
the test must report a skip for only the real parser check while retaining
static policy assertions; staging acceptance must run real `visudo`.

- [x] **Step 8: Commit installer and package integration**

```bash
git add install/common/sudo/vesta-compose-users \
  bin/v-install-docker-shell-access bin/v-install-docker-service \
  install/vst-install-debian.sh install/vst-install-ubuntu.sh \
  install/vst-install-rhel.sh install/vst-install-amazon.sh \
  src/deb/vesta/postinst src/rpm/specs/vesta.spec \
  example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users \
  test/compose/test-shell-access-install.sh \
  test/compose/test-package-integration.sh
git commit -m "feat(compose): install tenant Docker shell access"
```

#### Closeout Report

- Summary: Added the exact broker-only sudo policy, atomic trusted installer/repair, synthetic-root mirror, lifecycle installer wiring, and executable policy/failure tests.
- Files changed: `install/common/sudo/vesta-compose-users`, `example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users`, `bin/v-install-docker-shell-access`, installer/postinst/spec/service files, and install/package tests.
- Tests: Installer/visudo, package integration, policy mirror, malicious-input, isolation, Docker readiness, syntax, and `git diff --check` PASS.
- Commit SHA(s): `e80485ca`, `309bf712`.
- Spec review: APPROVED after trust-chain, writable-path, atomic-policy, and failure-matrix remediation.
- Code quality review: Deferred to final closeout per milestone-driven workflow.
- Follow-ups or concerns: Root/disposable real-sudo execution remains Task 9 acceptance work.

### Task 9: Prove the real privilege boundary in a disposable host

**Files:**

- Create: `test/compose/test-shell-access-root-integration.sh`
- Create: `.docs/validation/2026-08-07-compose-shell-access-development.md`
- Modify: `test/compose/test-docker-readiness.sh`
- Modify: `test/compose/test-malicious-input.sh`
- Modify: `test/compose/test-policy.sh`

- [x] **Step 1: Add a root-only disposable integration test**

The test creates temporary Unix users `vx-shell-alice` and `vx-shell-bob`, a
temporary Vesta tree, one `standard` fixture per owner, and a fake Docker
binary. It installs the sudo policy into a disposable namespace/container when
available; it must never edit the developer host's real groups or sudoers.

The test proves:

```text
alice can list/health/start only alice/app
alice cannot reference bob/app or claim admin
alice cannot use a nonstandard project
alice cannot sudo any other Vesta command, docker, bash, sh, env or interpreter
alice cannot read or write docker.sock
alice cannot inject VESTA, PATH, HOME, BASH_ENV, LD_PRELOAD, DOCKER_HOST,
  COMPOSE_FILE or VX_COMPOSE_* into the child
alice loses access immediately after quota removal, shell disable or suspension
membership is restored only after valid unsuspension/re-entitlement
```

Always remove only the exact disposable users, namespace, fake state, and
temporary policy created by the test.

- [x] **Step 2: Extend malicious policy fixtures through the broker**

Feed the existing fixtures for privileged mode, Docker/containerd sockets,
host PID/IPC, devices, unsafe capabilities, host networking, arbitrary host
paths, reserved ownership labels, cross-owner volumes/networks/ports, and
unapproved security options through `v-docker preview`. Assert rejection before
the fake Docker mutation log.

- [x] **Step 3: Run root integration on a disposable staging host**

Run:

```bash
sudo -n bash test/compose/test-shell-access-root-integration.sh
```

Expected: PASS. Then manually verify in the disposable host:

```bash
sudo -l -U vx-shell-alice
```

Expected: only
`/usr/local/vesta/bin/v-run-user-docker-command *`; no other NOPASSWD command.

- [x] **Step 4: Deploy the exact implementation commit to the development server**

This step is authorized only for the development Vesta host
`debian@192.168.100.100`, reached through
`gizmo@192.168.100.16`. Do not connect to, deploy to, restart, or mutate
production. Do not use a hostname alias for the target and do not use
`rsync --delete`.

Require a clean, remotely recoverable implementation commit:

```bash
git diff --exit-code
git diff --cached --exit-code
release_commit="$(git rev-parse HEAD)"
git branch -r --contains "$release_commit"
```

Expected: both diffs are empty and a pushed remote branch contains the exact
commit. Build an overlay containing only the runtime files changed by this
feature:

```bash
overlay_root="$(mktemp -d /var/tmp/vesta-shell-access-overlay.XXXXXXXX)"
git archive "$release_commit" \
  bin/v-docker \
  bin/v-run-user-docker-command \
  bin/v-sync-docker-shell-access \
  bin/v-sync-docker-shell-access-all \
  bin/v-install-docker-shell-access \
  bin/v-install-docker-service \
  bin/v-add-user \
  bin/v-change-user-package \
  bin/v-update-user-package \
  bin/v-change-user-shell \
  bin/v-suspend-user \
  bin/v-unsuspend-user \
  bin/v-rebuild-user \
  bin/v-delete-user \
  func/vx/compose/main.sh \
  func/vx/compose/package.sh \
  func/vx/compose/shell-access.sh \
  func/vx/compose/audit.sh \
  web/inc/vx_compose_package.php \
  web/add/package/index.php \
  web/edit/package/index.php \
  web/templates/admin/add_package.html \
  web/templates/admin/edit_package.html \
  install/common/sudo/vesta-compose-users \
  | tar -x -C "$overlay_root"
printf '%s\n' "$release_commit" >"$overlay_root/RELEASE_COMMIT"
tar -C "$overlay_root" -czf \
  "/var/tmp/vesta-shell-access-$release_commit.tar.gz" .
(
  cd /var/tmp
  sha256sum "vesta-shell-access-$release_commit.tar.gz" \
    >"vesta-shell-access-$release_commit.tar.gz.sha256"
)
```

Transfer through the approved jump host:

```bash
scp -o ProxyJump=gizmo@192.168.100.16 \
  "/var/tmp/vesta-shell-access-$release_commit.tar.gz" \
  "/var/tmp/vesta-shell-access-$release_commit.tar.gz.sha256" \
  debian@192.168.100.100:/var/tmp/
ssh -J gizmo@192.168.100.16 debian@192.168.100.100
```

On `192.168.100.100`, run `sha256sum -c` from `/var/tmp` against the transferred
checksum file, extract the archive to a root-owned temporary directory, run
Bash/PHP syntax checks there, and
snapshot every destination that will be replaced beneath a root-owned backup
directory named with the exact commit. Apply with `rsync -a` per listed file or
directory, without `--delete`, then run:

```bash
sudo /usr/local/vesta/bin/v-install-docker-shell-access
sudo /usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users
sudo /usr/local/vesta/bin/v-sync-docker-shell-access-all
sudo /usr/local/vesta/bin/v-check-docker-engine json
```

Expected: installer, sudo policy, full reconciliation, and Docker readiness all
pass. Record the local commit, remote archive checksum, backup path, installed
file modes/owners, and command output in
`.docs/validation/2026-08-07-compose-shell-access-development.md`. If syntax,
installation, or readiness fails, disable the new sudoers rule first, restore
only the exact snapshotted files, rerun `visudo` and Docker readiness, and stop
the acceptance run.

- [ ] **Step 5: Exercise real Docker-enabled Vesta users on `192.168.100.100`**

Under one root-owned test lock, create disposable Vesta users named
`vxshalpha`, `vxshbeta`, and `vxshzero`. Create a disposable package named
`vx-shell-e2e` through `v-add-user-package`; it must use Bash and explicit
nonzero `DOCKER_PROJECTS`, service, CPU, memory, PID, storage, port, secret,
and volume quotas. Keep `vxshzero` on a zero-Docker package. Generate test
passwords in root-owned mode-`0600` files and do not record them in evidence.

Seed one administrator-selected, immutable registry digest for the two
`standard` test projects. Record whether its image existed before the test.
Create `vxshalpha/app` and `vxshbeta/app` through each user's own immutable
`v-docker preview ... < compose.yaml` and `v-docker apply ...` flow; do not
use a privileged profile, workload-bundle import, raw tenant Docker, host
networking, host paths, or published host ports.

Prove on the live development host:

```text
vxshalpha and vxshbeta are automatically in vesta-compose-users
vxshzero is not in vesta-compose-users
sudo -l -U vxshalpha exposes only v-run-user-docker-command
vxshalpha can list, show, validate, health, stop, start, restart and probe alpha/app
vxshalpha cannot name or access vxshbeta/app, claim admin, or use a nonstandard profile
vxshalpha cannot sudo another v-* command, docker, docker compose, bash, sh, env or an interpreter
vxshalpha cannot read or write /var/run/docker.sock
malicious Compose definitions are denied before a Docker mutation
an already-open vxshalpha shell is denied immediately after package quota becomes zero
an already-open vxshalpha shell is denied immediately after Bash is changed to nologin
an already-open vxshalpha shell is denied as suspension begins and cannot restart its project
valid package/shell/unsuspension restores membership and owner-only access
removing eligible membership and rerunning v-install-docker-shell-access repairs it
rerunning the installer and full reconciliation is idempotent
Docker labels remain vx.managed=true, vx.user=OWNER, vx.project=app with standard profile evidence
```

Use the root integration harness for stale-session and concurrency control;
do not approximate those checks with a fresh login. Capture bounded,
secret-free command results and exact exit codes in the development validation
document.

- [x] **Step 6: Clean development fixtures and verify the host remains healthy**

Delete the two test projects through Vesta while retaining no disposable test
data, then delete `vxshalpha`, `vxshbeta`, `vxshzero`, and the `vx-shell-e2e`
package through Vesta commands. Remove only the exact test archive, extraction
directory, password files, Compose inputs, previews, test backup records, and
test image if it was absent before the run and has no remaining Vesta/Docker
reference. Do not prune Docker globally.

Verify:

```bash
getent passwd vxshalpha && exit 1 || true
getent passwd vxshbeta && exit 1 || true
getent passwd vxshzero && exit 1 || true
sudo /usr/local/vesta/bin/v-sync-docker-shell-access-all
sudo /usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users
sudo /usr/local/vesta/bin/v-check-docker-engine json
sudo docker ps --filter label=vx.managed=true --format '{{json .}}'
```

Expected: disposable users/projects/files are absent, reconciliation and
sudoers validation pass, Docker orchestration remains ready, and unrelated
managed containers are unchanged. Record cleanup evidence and compare the
unrelated-container inventory to the pre-deployment snapshot.

- [x] **Step 7: Run focused security regressions**

Run:

```bash
bash test/compose/test-shell-access.sh
bash test/compose/test-shell-input.sh
bash test/compose/test-shell-access-concurrency.sh
bash test/compose/test-shell-access-install.sh
bash test/compose/test-malicious-input.sh
bash test/compose/test-policy.sh
bash test/compose/test-isolation.sh
bash test/compose/test-docker-readiness.sh
git diff --check
```

Expected: PASS.

- [x] **Step 8: Commit disposable and development-server acceptance evidence**

```bash
git add test/compose/test-shell-access-root-integration.sh \
  test/compose/test-docker-readiness.sh \
  test/compose/test-malicious-input.sh test/compose/test-policy.sh \
  .docs/validation/2026-08-07-compose-shell-access-development.md
git commit -m "test(compose): prove tenant shell isolation on development"
```

#### Acceptance Progress Report

- Exact pushed implementation `15c46d0d` passed
  `test/compose/run-production-readiness-limited.sh`; optimized ShellCheck,
  every Compose shell suite, fixture renders, PHP/JavaScript, documentation,
  Playwright discovery, and whitespace checks passed.
- The exact commit was deployed to `debian@192.168.100.100` through the
  required jump host. Overlay checksum, backup, staged syntax/`visudo`, final
  modes, exact installed hashes, reconciliation, Docker readiness, and actual
  rollback behavior are recorded in the development validation document.
- Real Vesta users proved exact broker-only sudo, Docker-socket denial,
  immutable preview/apply, lifecycle operations, deny-first policy, live
  shell/suspension/quota/group revocation, installer repair, idempotence, and
  clean fixture removal. The unrelated managed-container identity and
  canonical label set were unchanged. Production was not contacted.
- Step 5 remains open only for a successful persisted named-probe invocation;
  the standard Compose acceptance fixture defined no named probe. Undefined
  probes failed closed. All other listed development-host assertions passed.
- Step 3 passed in a temporary Debian 12 child of an already-present local
  image after completing the harness's minimum authoritative project fixture.
  The child added only `sudo` and `acl`, ran the harness with network disabled,
  and was removed afterward. Specification and code-quality reviews approved
  the test-only fixture correction.

### Milestone 3 security review gate

- [x] Review the actual `visudo -cf` result, installed modes/ownership,
  `sudo -l` output, group membership, and Docker socket permissions.
- [x] Verify package/shell/suspension/deletion hooks converge without manual
  group commands.
- [x] Verify rollback disables sudo first, removes all dedicated group members,
  removes the group only when empty, and leaves Docker projects, images,
  volumes, secrets, and package quota state untouched.
- [x] Verify the exact implementation commit was deployed and accepted on
  `debian@192.168.100.100` through `gizmo@192.168.100.16`, all disposable
  fixtures were removed, and the pre/post unrelated-container inventory
  matches.
- [x] Record milestone commit SHAs and staging evidence in this plan.

---

## Milestone 4: Documentation and release closeout

### Task 10: Document operation, ownership, recovery, and future extension

**Files:**

- Modify: `docs/container-orchestration.md`
- Modify: `.docs/contracts/compose-interfaces.md`
- Modify: `.docs/contracts/compose-policy.md`
- Modify: `.docs/contracts/compose-lifecycle.md`
- Modify: `.docs/user-guides/docker-compose-projects.md`
- Modify: `.docs/README.md`
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `AGENTS.md`
- Modify: `.agents/skills/bash-cli/SKILL.md`
- Modify: `.agents/skills/runtime-layout/SKILL.md`
- Modify: `test/test_compose_docs.sh`

- [x] **Step 1: Add failing documentation consistency checks**

Assert current docs name `v-docker`, `vesta-compose-users`, the exact broker,
package-derived entitlement, `standard`-only scope, bounded stdin, and the
automatic reconciliation command. Assert no current user guide recommends the
Docker group, Docker socket chmod/ACL, direct tenant sudo of `v-*`, caller
owner/actor arguments, raw Docker, or manual group maintenance.

- [x] **Step 2: Update the operator and user documentation**

Document this user workflow:

```bash
v-docker quota json
v-docker projects json
v-docker show app json
v-docker health app json
v-docker logs app app 100
v-docker preview app change < compose.yaml
v-docker apply app PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
v-docker restart app
```

Document that a new login may be required for the convenience group to appear
in the shell's supplementary group list, but live broker authorization changes
take effect immediately. Explain that administrators enable access by assigning
a package with `DOCKER_PROJECTS > 0` and an interactive Bash shell; Vesta owns
all group reconciliation.

- [x] **Step 3: Document administrator repair and rollback**

Add exact operations:

```bash
/usr/local/vesta/bin/v-sync-docker-shell-access USER
/usr/local/vesta/bin/v-sync-docker-shell-access-all
/usr/local/vesta/bin/v-install-docker-shell-access
/usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users
getent group vesta-compose-users
sudo -l -U USER
```

Rollback order is: disable/remove the exact sudoers file atomically, verify
the broker is absent from `sudo -l`, remove group members, remove the empty
dedicated group, then remove client/broker code. Rollback must not mutate
Docker, project state, images, volumes, secrets, routes, package quotas, or
application data.

- [x] **Step 4: Update agent guidance**

Add concise rules that future work must preserve kernel/sudo-derived identity,
owner equality, `standard` profile, bounded stdin, exact broker sudo, live
entitlement checks, access-lock-before-project-lock ordering, and the ban on
Docker group/socket access and direct existing-command sudo.

- [x] **Step 5: Run documentation and syntax validation**

Run:

```bash
bash test/test_compose_docs.sh
bash -n bin/v-docker bin/v-run-user-docker-command \
  bin/v-sync-docker-shell-access bin/v-sync-docker-shell-access-all \
  bin/v-install-docker-shell-access func/vx/compose/shell-access.sh
php -l web/inc/vx_compose_package.php
php -l web/add/package/index.php
php -l web/edit/package/index.php
php test/test_compose_package_form.php
git diff --check
```

Expected: PASS.

- [x] **Step 6: Run the complete focused shell-access suite**

Run:

```bash
for test_file in \
  test/compose/test-shell-access.sh \
  test/compose/test-shell-input.sh \
  test/compose/test-shell-access-concurrency.sh \
  test/compose/test-shell-access-install.sh \
  test/compose/test-package-integration.sh \
  test/compose/test-owner-lifecycle.sh \
  test/compose/test-preview-apply.sh \
  test/compose/test-secrets.sh \
  test/compose/test-registry.sh \
  test/compose/test-redaction.sh \
  test/compose/test-isolation.sh \
  test/compose/test-operator-controls.sh \
  test/compose/test-malicious-input.sh \
  test/compose/test-policy.sh; do
    bash "$test_file" || exit
done
```

Expected: every test passes sequentially.

- [x] **Step 7: Run the full release gate in a resource-safe environment**

Run only after the focused suite passes and on a host sized for the complete
gate:

```bash
test/compose/run-production-readiness-limited.sh
git diff --check
```

Expected: PASS. The repository-owned launcher applies validated cgroup CPU,
dynamic memory, swap, task, and nice limits before running the canonical gate
unchanged. It reserves 2 GiB of available memory for the host. The gate checks
adapters locally once and follows the shared Compose helper graph once. Do not
run concurrent ShellCheck workers or restore per-adapter `shellcheck -x` on
constrained machines. Use `VX_READINESS_*` overrides only to match an approved
host's capacity; an unsupported limited environment fails closed unless the
operator explicitly sets `VX_READINESS_ALLOW_UNLIMITED=yes` on an
unconstrained host.

- [x] **Step 8: Commit documentation and closeout**

```bash
git add docs/container-orchestration.md .docs/contracts/compose-interfaces.md \
  .docs/contracts/compose-policy.md .docs/contracts/compose-lifecycle.md \
  .docs/user-guides/docker-compose-projects.md .docs/README.md README.md \
  SECURITY.md AGENTS.md .agents/skills/bash-cli/SKILL.md \
  .agents/skills/runtime-layout/SKILL.md test/test_compose_docs.sh
git commit -m "docs(compose): document tenant Docker shell access"
```

#### Task 10 closeout report

- Documentation and consistency checks: PASS in `d380bab8`.
- Focused shell-access matrix: all 14 suites PASS; subsequent changes were
  covered by their affected package, installer, shell-access, lifecycle, and
  transaction regressions.
- Independent specification review: APPROVED for the exact executable
  39-operation catalog and contract parity.
- Independent code-quality/security review: APPROVED after remediation commits
  `d6561990`, `1cccf02a`, `1f765292`, `453721c7`, and `da52561b`.
- Full release gate: PASS at exact pushed implementation `15c46d0d` through
  the repository-owned constrained launcher. No direct broad gate or
  unlimited override was used.
- Development acceptance: PASS for deployment, real-user sudo/orchestration,
  revocation, repair, idempotence, cleanup, and disposable-container checks.
  The successful named-probe check remains explicitly open under Task 9.

### Final acceptance gate

- [x] Eligible Docker-enabled Bash users are added automatically to exactly
  `vesta-compose-users`; no manual group work is required.
- [x] The dedicated group grants only the exact root broker and no Docker
  socket, Docker group, wildcard Vesta command, shell, or interpreter access.
- [x] The broker authenticates from `SUDO_UID`/passwd, never accepts owner,
  actor, or profile, and operates only on the actor's `standard` projects.
- [x] Suspension, package removal, shell disable, deletion, malformed state,
  and stale membership fail before Docker.
- [x] Compose, secret, and registry input is bounded stdin with root-owned
  immutable snapshots and complete cleanup.
- [x] Preview/apply, rollback, reconcile, labels, quota, policy, redaction,
  backup, and project-lock contracts remain intact.
- [x] Package add/edit surfaces preserve all nine Compose quota dimensions.
- [x] Fresh install, package update, Docker installation, repair, and rollback
  converge group/sudoers state deterministically.
- [x] Disposable real-sudo acceptance proves cross-owner, privileged-profile,
  raw Docker, arbitrary command, environment, and filesystem attacks fail.
- [x] The exact remotely recoverable implementation commit passes deployment,
  real-user orchestration, revocation, reconciliation, cleanup, and unchanged
  unrelated-container checks on `192.168.100.100` through the required jump
  host; no production system is accessed.
- [x] Documentation, focused tests, resource-safe readiness, and
  `git diff --check` pass.

## Self-review result

- **Spec coverage:** automatic Vesta-owned permissions, Docker-enabled package
  authority, SSH shell use, owner scoping, safe management operations,
  installer/update convergence, revocation, explicit development-server
  deployment, cleanup, documentation, and security tests are each assigned to
  explicit tasks.
- **Complexity check:** one group and one broker reuse the existing Vesta
  policy/transaction system; no daemon, Docker proxy, per-user group, socket
  ACL, duplicated orchestrator, or application-specific command is introduced.
- **Completeness scan:** the implementation tasks contain exact paths,
  interfaces, invariants, commands, expected failures, tests, and commits;
  every implementation decision required by this plan is explicit.
- **Type/name consistency:** `vesta-compose-users`, `v-docker`,
  `v-run-user-docker-command`, `v-sync-docker-shell-access`,
  `v-sync-docker-shell-access-all`, `v-install-docker-shell-access`, and
  `compose-shell-access.md` are used consistently throughout.
