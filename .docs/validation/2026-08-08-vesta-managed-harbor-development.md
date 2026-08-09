# Vesta-Managed Harbor Development Acceptance — 2026-08-08

## Outcome

**BLOCKED — PRODUCT.** Current HEAD was staged and the Vesta-managed Harbor
installer reached authenticated bootstrap, but Harbor v2.15.0 cannot satisfy
the approved publisher-secret and least-privilege integration contract. The
provider was returned to a stable disabled/inactive state. Production
deployment is deferred and no production host was contacted.

Development DNS is also not ready for unpinned clients: the workstation's
resolver returns `203.0.113.10` for `development.example.com`, not the authorized
development address `192.0.2.10`. All SSH and hostname-bearing TLS probes
in this acceptance were pinned to `192.0.2.10`; the raw IP was never used
as the TLS identity.

## Release identity and authorization boundary

- Repository start point: `8f1b6b9d`.
- Exact final staged commit:
  `6c7119b86eb3324e87fe43203bc6a69b41280314`.
- Installed runtime version: `0.9.9-0-16+vxapp.6c7119b8`.
- Final runtime archive SHA-256:
  `fd6073a78cf965474f072216cdce8eefca13b41b6d7dfc3d233ddaf4e9629766`.
- Runtime payload: 57 repository files; all 57 installed hashes passed.
- SSH target: `operator@development.example.com`, pinned to
  `192.0.2.10` with the configured `~/.ssh/id_ed25519`.
- Host-reported FQDN: `development.example.com`; host address:
  `192.0.2.10/24`; SSH peer target: `192.0.2.10:22`.
- No firewall, DNS, route, tenant package, tenant desired-state, or unrelated
  package change was made. No Docker prune was run.
- `production.example.com` was not contacted or mutated. Production
  deployment and push remain deferred.

## Local Milestone 5 run

The requested clean aggregate was run once after two focused fixture
corrections:

```text
bash test/harbor/run-focused.sh
exit=0
PASS: Harbor fixture tests
PASS: Harbor provider state
PASS: Harbor redacted status and endpoint guards
PASS: Harbor package/quota integration
PASS: Harbor release verification
PASS: Harbor transactional install
PASS: Harbor exact ingress boundary
PASS: Harbor host boundary
PASS: protected Harbor API adapter
PASS: owner reconciliation
PASS: runtime credential lifecycle
PASS: publisher credential lifecycle
PASS: tenant discovery
PASS: revocation and outage isolation
PASS: bounded Harbor health observations
PASS: encrypted Harbor backup and validate-only restore
PASS: Harbor disable plan
PASS: Harbor documentation contract
PASS: Harbor panel integration
```

Earlier defect-discovery starts of the aggregate failed before this clean run;
they are not represented as passes. The aggregate was not run again after the
clean result. No broad standalone ShellCheck, canonical/full readiness gate,
limited launcher, or unlimited launcher was run in this acceptance.

Focused corrections before the clean run were `f7ce90a6` and `5d48a72e`.
Live acceptance then exposed and focused-tested these install corrections:

```text
632e0e48 validate containerd-loaded generator identity
ba9b154f remove failed preactivation staging
c0ebb951 generate external proxy configuration
27acfc15 converge isolated provider activation
e211c792 preserve generator capability contract
7389311c create registry socket with panel access
d2948876 supervise protected registry socket
4d5fd098 roll back fresh provider data
d351b590 normalize resumable bootstrap state
6c7119b8 set nonexpiring robot duration
```

Only affected Bash syntax, focused Harbor tests, Python fixture checks, and
`git diff --check` were used after live defect discovery.

## Development baseline and TLS

- The authoritative Vesta hostname and interface are
  `development.example.com` and `192.0.2.10/24`.
- The host resolver maps `development.example.com` to `192.0.2.10`, while the
  acceptance workstation's resolver maps it to `203.0.113.10`.
- The panel listener is `0.0.0.0:8083` and returns HTTP `302` when probed as
  `https://development.example.com:8083` with the connection pinned to
  `192.0.2.10`.
- Panel certificate subject and issuer CN are both
  `development.example.com`. Validity is 2025-11-29 09:21:20 UTC through
  2026-11-29 09:21:20 UTC. SHA-256 fingerprint is
  `18:2E:30:BF:6D:19:76:93:5F:6D:32:43:37:8E:B2:C5:3A:52:0E:2F:EA:5F:8B:A1:A3:3D:1B:F0:44:A9:3B:5F`.
- The certificate is self-signed (`curl` verification result 18), so the
  hostname and validity checks pass but public CA trust is not claimed.
- Exact Debian `cosign 2.5.0-2+b4` was installed as the
  release-verification prerequisite. No unrelated package was installed.

## Transactional staging and rollback

Each successor was staged under `/run/lock/vesta-vxapp-release.lock`. The
final transaction captured prior bytes, absent paths, created directories,
version, active containers, listeners, release metadata, archive hash, and
restoration instructions before installing only the 57-file runtime payload.
Installed hashes and syntax passed; unrelated files were not deleted.

The final retained root-owned mode-0700 rollback is:

```text
/root/vesta-backups/vesta-harbor-task10-6c7119b8-20260808T125339Z
```

It contains 75 evidence files (467472 bytes), including `RESTORE.txt`, and
records the exact staged commit and archive hash. Earlier successor rollbacks
from `5d48a72e` through `d351b590` are also retained. The historical path
`/root/vesta-backups/vesta-harbor-task10-dc48f21e` does not exist on this new
development host; it was neither contacted nor deleted.

The root filesystem had 6530224 KiB free at closeout. Because the pinned
offline Harbor release and retained rollback/data reduced free space below
the original conservative preflight threshold, later resumable attempts used
an explicit 6000000 KiB minimum. No global image/container cleanup was used.

## Install transaction and product blocker

The final installer log reached the following redacted phases:

```text
PHASE=prerequisite
PHASE=release
PHASE=generation
PHASE=compose
PHASE=migration
PHASE=socket
PHASE=health
exit=75 before PHASE=integration
```

The protected failure evidence is retained in the final rollback. Harbor's
response was:

```text
BAD_REQUEST: bad request permission: project:update
```

Harbor v2.15.0's authenticated `/api/v2.0/permissions` response proves that
`project:update` is project-scoped and that neither system nor project robot
permission catalogs offer `robot:update`. A disposable probe then established
the deeper incompatibility without exposing credentials:

```text
valid integration robot create:                 201
delegated scoped child robot create:             201
integration robot refresh of child secret:       403
child robot refresh of its own secret:            403
requested creation secret equals returned secret: false
returned generated credential /v2/ probe:         200
```

Harbor also prefixes the returned login (`robot$...`) and always generates the
creation secret. Consequently the approved behavior cannot be achieved on the
pinned release: `v-docker registry-publisher-change` requires a
caller-generated publisher secret, Vesta must not return or retain that
publisher secret, and the bootstrap administrator must not be used for
routine API calls. Using the retained bootstrap administrator to PATCH every
publisher robot would violate the least-privilege contract; accepting a
server-generated secret would leave the tenant without the submitted
credential and violate the publisher lifecycle contract. The acceptance did
not weaken either boundary.

All disposable probe robots and the disposable `vesta-probe-contract` Harbor
project were deleted. Final authenticated inventory reported zero matching
probe robots and zero matching probe projects. No Vesta owner, Compose
project, or tenant container was created for these probes.

## Final development state and workload preservation

The isolated candidate had ten healthy/internal Harbor containers and no
published host port during diagnosis. At closeout only
`vesta-harbor.service` was stopped and disabled. Harbor data, stopped
containers, logs, staged runtime, rollback evidence, and the unit were
retained; no prune or provider-data deletion was performed.

```text
provider MODE=disabled
provider PINNED_VERSION=v2.15.0
provider RUNNING_VERSION=null
provider ORIGIN=null
vesta-harbor.service=inactive,disabled
/run/vesta-harbor/registry.sock=absent
Harbor host TCP listener=absent
panel listener=0.0.0.0:8083
```

The active tenant baseline was checked before staging, during each install
monitor, after every failure/probe, and after final service shutdown. It is
unchanged:

```text
fabfe8153757c9a08d95a89b357b254fd7911f79e8fc08e10afeb2fa03c63520
/vx-legacyadmin-legacy-admin-app-app-1 running healthy
```

`legacy-admin-app` desired state, image, container, network, volumes, routes, and
credentials were not mutated.

## Acceptance not claimed

Because the shipped adapter cannot establish its required routine identity,
Task 10 does not claim managed provider activation, eligible-owner quota,
distinct usable runtime/publisher credentials, immutable push/pull by digest,
`v-docker` registry workflow, revocation, outage isolation, encrypted backup
validation, provider health, or disable-plan acceptance. No workload was
mutated to simulate those checks.

## Required product decision

Before Task 10 can resume, the approved design must choose and implement a
Harbor-supported credential contract, for example a pinned Harbor release
that accepts caller-selected robot secrets under delegated authority, or an
explicitly reviewed change to secret delivery/administrator use. Development
DNS must also map `development.example.com` to `192.0.2.10` for unpinned
clients. Then stage the exact successor HEAD, create a new rollback, and rerun
only the incomplete development-host acceptance. Production remains deferred.

## Source-validated resolution — 2026-08-09

The failed development evidence above is preserved as observed; none of its
blocked checks are relabeled as passing. The product decision is now resolved
in source and contract, but development acceptance remains incomplete.

The selected behavior is pinned to Harbor v2.15.0 commit
`e2b5ce92728f86c4b02f6a9a667741c1e5b62678`:

- `src/controller/robot/controller.go` calls `CreateSec` unconditionally,
  stores the generated hash, returns the generated plaintext once, composes a
  project stored name as `PROJECT+ROBOT_BASENAME`, and adds the configured
  prefix when populating the API model.
- `src/server/v2.0/handler/robot.go` does not copy
  `RobotCreate.secret` into the controller model, returns the generated value
  in `RobotCreated.secret`, permits a robot-created child only when its
  permission set is a subset of the creator, and gates update and refresh on
  `robot:update`.
- `src/common/rbac/const.go` exposes robot create/read/list/delete in the
  system and project robot catalogs but deliberately omits `robot:update`.
- `src/server/v2.0/handler/model/robot.go` builds ordinary robot read/list
  models without a secret field.

The corrected Vesta contract therefore uses one system integration robot with
system scope `/` and wildcard project scope `*`. It creates project-level
runtime pull-only and publisher pull-plus-push children only when those
permissions are subsets. Routine Vesta performs create, verify, metadata
switch, and validated delete; it never updates or refreshes a robot and never
falls back to the retained bootstrap administrator.

The owner publisher command is now
`v-docker registry-publisher-rotate < age-recipient`. Harbor generates the
publisher secret once. Vesta verifies it and sends only complete
ASCII-armored age ciphertext to stdout. Publisher plaintext is never durable
on Vesta. The runtime plaintext-equivalent remains protected Vesta authority
for unattended pulls. Every create carries a non-secret candidate marker so a
committed child with a lost response can be discovered and deleted before a
fresh retry. Revocation is a successful child delete followed by a validated
not-found read; the private project and artifacts remain. Project requests use
only supported private metadata, exactly `{"public":"false"}`.

The repository fixture and its network-free behavioral source-parity test now
encode those upstream rules, including generated one-time secrets, configured
prefixes, exact levels/scopes, subset enforcement, `403` update/refresh,
secret-redacted GET/list, validated delete, and a marked lost-response
candidate. This is design and local fixture evidence only. No corrected
successor was staged on `development.example.com`, the incomplete live checks in
"Acceptance not claimed" were not rerun, the DNS discrepancy was not
revalidated, and no production host was contacted. Development acceptance and
all production deployment remain deferred.

## Generated-credential successor attempt — 2026-08-09

This section supersedes only the final staging statement immediately above.
The historical failures and the checks not claimed remain preserved.

### Bounded local validation

The corrected generated-credential implementation passed one clean focused
Harbor aggregate at `f41990e9`, including fixture/source parity, install,
ingress, protected API, runtime and publisher rotation, revocation, backup,
documentation, and panel checks. Subsequent live defects were checked only by
their directly affected tests plus touched syntax and `git diff --check`.

The repository-owned limited readiness launcher was attempted once. Its
single source-following ShellCheck process made no diagnostic progress for
approximately 20 minutes, performed more than 57 GB of disk reads, and
exhausted system swap. It was terminated to prevent another workstation or
Codex-session failure and exited `143`. This is not recorded as a pass, and
the launcher was not rerun. No broad ShellCheck, direct canonical gate, or
unlimited launcher was substituted.

### Exact development staging

The final staged source identity is:

```text
commit=e3b2b19d6d85e96cf29cad24d4798e20eb318f11
runtime_version=0.9.9-0-16+vxapp.e3b2b19d
final_archive_sha256=7d47fe89ebb4e235f2a09b1a1753506b7c16c1b6623305e6ae99d28f5fdd1b72
final_runtime_files=2
rollback=/root/vesta-backups/vesta-harbor-task10-e3b2b19d-20260809T023738Z
```

The final two-file successor followed the complete generated-credential
runtime staged at `f41990e9`, then the bounded live corrections at `5725323e`
and `08446067`. Every transaction used the release lock, captured prior bytes,
installed exact archive hashes, ran touched syntax/hash checks, retained a
root-owned mode-0700 rollback, and compared active container IDs before and
after. No firewall, route, DNS, package, tenant desired-state, volume, bind,
or credential was changed.

### Live defects corrected

Development-host evidence found and focused-tested three concrete adapter
defects:

1. Harbor v2.15.0 rejects robot-list `page_size=1000` with `422`; both system
   and project robot discovery now use bounded 100-item pagination.
2. The protected API adapter incorrectly expected a `root:root` socket; it
   now uses the existing exact `root:www-data:0660` ingress-socket validator.
   Failed candidate rollback also removes only the validated stale socket.
3. Ingress activation edited Vesta's panel nginx configuration while testing
   and reloading Debian's separate nginx service. It now tests the candidate
   and activated configuration with
   `/usr/local/vesta/nginx/sbin/vesta-nginx`, validates the root-owned PID and
   running executable, and signals that exact panel master.

The protected marker-only transaction after the socket correction reached a
healthy ten-container provider, created and validated the generated
integration identity, completed the delegated project/robot probe, and exited
the integration function successfully. No marker recorded arguments, API
bodies, usernames, passwords, robot secrets, or ciphertext.

### Stable closeout and remaining blocker

The final uninstrumented transaction at `e3b2b19d` again reached
`prerequisite`, `release`, `generation`, `compose`, `migration`, `socket`, and
`health`, but did not complete the integration phase. Its transactional
rollback completed. Further live retries were stopped to avoid a circular
diagnostic loop. Managed-provider acceptance, tenant publisher delivery,
quota/revocation/outage checks, backup validation, and administrative disable
are therefore still not claimed.

Final development state is stable and fail-closed:

```text
provider MODE=disabled
provider PINNED_VERSION=v2.15.0
provider RUNNING_VERSION=null
provider ORIGIN=https://development.example.com:8083
vesta-harbor.service=inactive,disabled
/run/vesta-harbor/proxy.sock=absent
Harbor containers=absent
Harbor host TCP listener=absent
tenant_container=fabfe8153757c9a08d95a89b357b254fd7911f79e8fc08e10afeb2fa03c63520
tenant_state=running,healthy
tenant_image=sha256:e274e28000ab05e5a81c3fecae992ef3c06094b0701dfa9e965e8f23de0302fd
```

The deployment client still resolves `development.example.com` to
`203.0.113.10`, where panel port `8083` is refused, rather than directly to
the authorized development address `192.0.2.10`. When TLS is connected
to `192.0.2.10` with SNI and hostname `development.example.com`, system-store
verification succeeds. No hosts-file, DNS, certificate, or trust setting was
changed.

Production was not contacted or changed. Production deployment remains
deferred.
