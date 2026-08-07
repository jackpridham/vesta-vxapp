# Compose Shell Access Development Validation — 2026-08-07

## Scope and release identity

This record covers the tenant Docker shell-access release on the authorized
development Vesta host `debian@192.168.100.100`, reached only through
`gizmo@192.168.100.16`. Production was not contacted.

- Exact deployed implementation commit:
  `15c46d0dd8fcfe4f0db4cf8dda27af4f6a18f446`.
- Pushed branch: `origin/codex/vesta-user-docker-shell-access`.
- Corrected overlay archive SHA-256:
  `51237c49390b730d97b6cdd9975d61d5ebe61653a1ab32c04db71177fa8ed826`.
- Retained rollback backup:
  `/var/backups/vesta-shell-access-15c46d0dd8fcfe4f0db4cf8dda27af4f6a18f446.retry1`,
  root-owned mode `0700`.
- Exact post-deployment hashes for every overlay file matched `git show` from
  the implementation commit.

The transferred archive, checksum, staging trees, disposable password and
Compose files, stale-session coordination files, old attempt archives/stages,
and obsolete backups were removed after acceptance. The final rollback backup
is the only remaining `vesta-shell-access-*` deployment artifact on the host.

## Local release gate

`test/compose/run-production-readiness-limited.sh` passed at exact pushed head
`15c46d0d`. The launcher reported CPU `50%`, memory high/max limits, 512 MiB
swap, `TasksMax=64`, and nice level 19, then ran the canonical readiness gate
unchanged. Optimized ShellCheck, all Compose shell suites, committed fixture
renders, PHP and JavaScript checks, documentation consistency, Playwright
discovery, and working-tree whitespace passed.

An initial limited-gate run at `039382d5` stopped safely on ShellCheck SC2154
because `snapshot_file` was assigned through a nameref. Commit `727f4864`
added an explicit broker initialization; focused tests and both review gates
approved it before the successful limited-gate rerun.

The root-only disposable-container harness passed after its project fixtures
were completed with the same minimum authoritative files used by the broker
namespace fixture. A temporary Debian 12 child of the already-present
`asterisk-vxapp:20260807-7ad46403a` image added only `sudo` and `acl` and ran
with `--network none`. It proved real sudo installation, two-user owner and
profile isolation, raw-command/environment/socket denial, and immediate
quota/shell/suspension revocation. The child image was removed after the run.
An earlier Alpine attempt was rejected by the installer's Debian-compatible
local-system-group invariant and was also removed; no Alpine result is claimed.

## Deployment and rollback evidence

The clean baseline had `/usr/local/vesta` owned by `debian:debian` mode `0775`,
no feature sudoers file, no `vesta-compose-users` group, no global client link,
no disposable users, and ready Docker orchestration.

The first deployment attempt used the repository's default archive umask,
which emitted indexed `0644` files as `0664`. The installer rejected the
group-writable sudo-policy source with `sudo policy source is not trusted`.
The armed rollback removed the sudo policy and group first, restored only the
snapshotted files and top-directory metadata, removed the newly installed ACL
package, passed global `visudo`, passed Docker readiness, and confirmed the
managed-container inventory was unchanged.

The retry used `git -c tar.umask=0022 archive`. Remote checksum verification,
Bash syntax, PHP `-n -l`, staged `visudo`, installer, full reconciliation, and
Docker readiness all passed. Final installed evidence was:

```text
/usr/local/vesta                                      root:root 0755 directory
/usr/local/vesta/bin/v-docker                         root:root 0755 regular file
/usr/local/vesta/bin/v-run-user-docker-command        root:root 0755 regular file
/usr/local/bin/v-docker                               root:root exact symlink
/etc/sudoers.d/vesta-compose-users                    root:root 0440 regular file
```

The `acl` package remains installed because `getfacl` is a declared live
eligibility dependency.

## Real-user privilege boundary

Under `/run/lock/vesta-shell-access-acceptance.lock`, the test created package
`vx-shell-e2e` with Bash and explicit nonzero limits for projects, services,
CPU, memory, PIDs, storage, ports, secrets, and volumes. Users `vxshalpha` and
`vxshbeta` converged automatically into `vesta-compose-users`; zero-entitlement
`vxshzero` did not. Passwords existed only in root-owned mode-`0600` files and
were never recorded.

`sudo -l -U vxshalpha` exposed only:

```text
(root) NOSETENV: NOPASSWD: /usr/local/vesta/bin/v-run-user-docker-command *
```

The live boundary allowed alpha quota/project reads and denied the zero-quota
user, raw Docker and Docker Compose, Bash/sh, `env`, direct existing Vesta
commands, caller environment injection, cross-owner/path input, caller `admin`
input, and Docker-socket read/write. The socket remained root-owned, group
`docker`, mode `0660`; no tenant joined that group.

## Immutable deployment and policy acceptance

The image
`nginxinc/nginx-unprivileged@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0`
already existed and was retained. Both users created `app` through their own
`v-docker preview app add < compose.yaml` and digest/revision-bound
`v-docker apply` path. Alpha preview ID
`a364cabb9f1b5494922b3719ba235463` and beta preview ID
`156d3d2e1f151f6606623d0076c47c9e` both produced healthy revision 1 standard
projects. This directly validates the corrected
`/tmp/vx-compose-web.<32 hex>/compose.yaml` broker snapshot contract.

Alpha successfully ran show, validate, health, stop, start, and restart; start
and restart returned the container to healthy state. Runtime evidence showed
`vx.managed=yes`, `vx.user=vxshalpha`, `vx.project=app`, `vx.revision=1`,
standard profile authority, all capabilities dropped, no-new-privileges,
non-host networking, no published ports, no privileged mode, and no Docker
socket mount. A privileged Compose submission was denied with exit 2 before
desired-state or Docker mutation. An undefined named probe failed closed; a
successful named-probe path was not claimed because the seeded standard
Compose fixture did not define a persisted probe.

## Revocation, repair, and cleanup

One already-running alpha shell process was retained across each transition.
It demonstrated:

```text
baseline                 allow exit=0
shell changed to nologin deny  exit=1
shell restored to Bash   allow exit=0
user suspended           deny  exit=1 (project stopped)
user unsuspended         allow exit=0 (project restored healthy)
live group entry removed deny  exit=1 despite stale kernel group
installer repair         allow exit=0
DOCKER_PROJECTS=0        deny  exit=1 despite stale kernel group
eligible package restored allow exit=0
```

The zero-project transition used a temporary Bash package with
`DOCKER_PROJECTS=0` and unlimited non-project Docker dimensions so retained
test storage remained covered by the supported package-change path. The
temporary package was deleted after restoration. Repeated installer and full
reconciliation runs were idempotent and retained exactly alpha and beta while
eligible.

Both projects were removed through each owner's `v-docker remove app
keep-data` path. All three users and both temporary packages were then deleted
through Vesta. Owner preview remnants, password/input files, retained test
data, containers, networks, and coordination files are absent. Final state:

```text
vesta-compose-users:x:988:
sudoers validation: PASS
full reconciliation: added=0 removed=0 unchanged=7 failed=0
Docker orchestration readiness: yes
```

The unrelated managed container retained the same container ID
`fa36ad4cc920`, name `vx-asteriskvx-pbx-asterisk-1`, image `dea978c924ba`, and
canonicalized label set across cleanup. No global prune, firewall change,
production access, or unrelated workload mutation occurred.
