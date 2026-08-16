# Harbor-Generated Robot Credential Lifecycle Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `$milestone-driven-implementation`. This is one coupled security correction:
> Harbor API parity, provider authority, runtime credentials, publisher
> delivery, revocation, and documentation must agree at each milestone. Use
> fresh reviewers at milestone boundaries. Do not split authority changes from
> their failure-recovery tests.

**Goal:** Correct the Vesta-managed Harbor integration so stock Harbor v2.15
generates every robot secret, Vesta rotates credentials through supported
create/delete operations, and an eligible Docker tenant can obtain a
publisher credential without Harbor administration, Debian sudo, raw Docker
access, or plaintext secret persistence on the Vesta host.

**Architecture:** Keep one root-owned, system-level Vesta integration robot
for routine Harbor API calls. Give it only the exact system permissions needed
for project/quota/health management and wildcard project permissions needed to
create, inspect, and delete project-level child robots. Runtime and publisher
credentials are separate project-level robots. Every rotation is
create-generated-secret, verify, journal, atomically switch authority, then
delete the old robot. Vesta persists the runtime pull secret because it must
perform unattended pulls. Vesta never durably stores the publisher secret;
instead it encrypts Harbor's one-time generated value to an ephemeral native
age recipient supplied by the tenant and returns only ASCII-armored
ciphertext. Revocation deletes the child robot while retaining its Harbor
project and OCI artifacts.

**Tech Stack:** Bash, Vesta flat-file authority, Harbor v2.15.0 REST and OCI
APIs, curl over a protected Unix socket, jq, age/age-keygen, Docker credential
helpers, Python fixture server, nginx, systemd, focused Bash/PHP/Python tests,
and the repository-owned resource-limited readiness launcher.

---

## Scope and release rules

This plan corrects the unreleased Harbor feature branch after development
acceptance proved its original secret contract incompatible with Harbor. The
old `registry-publisher-change < publisher-secret` interface has never reached
a managed development or production provider, so it has no deployed
compatibility guarantee. Replace it instead of retaining an unsafe alias.

Production remains explicitly deferred. Development deployment is permitted
only after the focused local milestones pass. It must preserve the existing
tenant workload, retain a root-owned rollback, and stop at a stable success or
rollback endpoint. Do not run broad standalone ShellCheck, the canonical full
gate directly, or an unlimited readiness run. The only release-level gate in
this plan is `test/compose/run-production-readiness-limited.sh`.

Do not weaken any existing boundary:

- Tenants do not receive Docker socket/group access, Harbor administration,
  Debian sudo, or caller-selectable owner/project/permission arguments.
- Secrets do not enter argv, environment, logs, HTML, metadata, audit records,
  Git, unencrypted backups, or world-readable temporary files.
- Harbor keeps no public host TCP listener. Public OCI traffic remains limited
  to the exact `/v2/` and `/service/token` routes on the Vesta hostname, panel
  port, and certificate.
- Runtime and publisher credentials remain separate and independently
  revocable.
- Package downgrade, owner suspension/deletion, provider disablement, and
  recovery remain journaled and fail closed.
- OCI deployment sources continue to require immutable
  `repository@sha256:digest` references.
- Application repositories continue to own Dockerfiles, build commands,
  Compose sources, application secrets, acceptance checks, and deployment
  adapters.

## Validated upstream facts

The implementation must cite and test these facts rather than infer behavior
from the generated OpenAPI model:

- Harbor v2.15.0 is tag `v2.15.0`, commit
  `e2b5ce92728f86c4b02f6a9a667741c1e5b62678`.
- Harbor v2.15.2 is tag `v2.15.2`, commit
  `080b0220574cc853ae1e2946ce7a5610ba855757`.
- `src/server/v2.0/handler/robot.go::CreateRobot` does not copy
  `RobotCreate.secret`. It calls the controller and returns the generated
  plaintext only in `RobotCreated.secret`.
- `src/controller/robot/controller.go::Create` calls `CreateSec()`
  unconditionally. `CreateSec()` generates a value satisfying Harbor's
  8–128-character lower/upper/number policy, stores only its derived form, and
  returns plaintext once.
- `RefreshSec` and `UpdateRobot` both call `requireAccess(..., ActionUpdate)`.
- `src/common/rbac/const.go::NolimitProvider.GetPermissions` grants robot
  create/read/list/delete at system and project scope but deliberately does
  not grant robot update at either scope.
- `src/common/security/robot/context.go::IsSysAdmin` always returns false for a
  robot security context. A robot therefore cannot obtain implicit
  administrator refresh/update authority.
- `CreateRobot` accepts a robot security context and
  `isValidPermissionScope` permits child permissions only when they are a
  subset of the creator's exact scope or wildcard project scope.
- Project-level child creation by a system robot is fixed for Harbor 2.15.0;
  upstream issue `goharbor/harbor#21406` is closed by `#22387` and tagged for
  2.15.0.
- Project-level robot creation stores `PROJECT+ROBOT_BASENAME` and returns the
  configured Harbor robot prefix plus that stored name. Vesta must persist the
  returned username and must not predict `robot$` or another prefix.
- Harbor's official robot-account documentation states that creation returns
  a one-time secret which cannot later be retrieved. Push permission must be
  paired with pull permission.
- Comparing the robot handler, controller, RBAC provider, and robot security
  context between v2.15.0 and v2.15.2 produces no diff. A 2.15 patch upgrade
  does not change this lifecycle.
- Native age recipients and identities are explicitly designed for stdin and
  stdout composition. This repository already uses `/usr/bin/age` for Harbor
  backup encryption, and the development environment has age 1.3.1.

Upstream source links to preserve in the corrected contract:

- `https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/server/v2.0/handler/robot.go`
- `https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/controller/robot/controller.go`
- `https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/common/rbac/const.go`
- `https://github.com/goharbor/harbor/blob/e2b5ce92728f86c4b02f6a9a667741c1e5b62678/src/common/security/robot/context.go`
- `https://github.com/goharbor/harbor/issues/21406`
- `https://github.com/goharbor/harbor/pull/22387`
- `https://goharbor.io/docs/2.12.0/administration/robot-accounts/`
- `https://github.com/FiloSottile/age`

## Decision record

Use stock Harbor's replacement lifecycle:

```text
create project robot
  -> capture Harbor-generated one-time secret in process memory
  -> verify returned identity, scope, expiry, and credential
  -> write durable non-secret rotation journal
  -> switch Vesta authority atomically
  -> delete prior robot
  -> converge/recover by operation marker
```

For runtime pulls, stage the generated secret in a root-owned mode-0600
candidate file, switch the Vesta-managed Docker auth atomically, then remove
the candidate. The resulting runtime auth is durable and included only in the
existing separately encrypted backup payload.

For publisher pushes, accept one native X25519 age recipient on bounded stdin.
Create and verify a generated publisher secret, encrypt it in process memory,
complete the authority switch and old-robot deletion, then emit only the
ASCII-armored age envelope. The local tenant workflow captures ciphertext,
checks the SSH exit status, and only then decrypts directly into
`docker login --password-stdin`. Vesta never stores publisher plaintext.

Use project-level child robots rather than system-level robots with
project-scoped repository permissions. This makes Harbor's own robot level,
project ID, list authorization, naming, and deletion checks match Vesta's
tenant boundary.

Use delete as the revocation primitive. `registry-publisher-disable` means
delete the publisher robot and clear publisher authority; it does not delete
the Harbor project, repositories, tags, manifests, blobs, quota record, or
runtime pull robot.

Do not use these alternatives:

- Do not send caller-generated `RobotCreate.secret`; Harbor ignores it.
- Do not grant or request `robot:update`; Harbor does not offer that grant to
  robots.
- Do not use the bootstrap administrator for ordinary tenant rotation. It is
  limited to provider installation, integration-identity replacement,
  administrative disablement, and restore.
- Do not return a publisher secret as terminal plaintext or JSON.
- Do not persist publisher plaintext in Vesta state or temporary files.
- Do not patch or fork Harbor. The supported create/delete API already
  provides the least-privilege lifecycle.
- Do not upgrade Harbor solely to address this problem. v2.15.2 has the same
  robot implementation and permission model.
- Do not use raw image archives, SCP/rsync, Docker group access, or direct
  Docker-over-SSH as fallback delivery paths.

## Fixed external interfaces

The corrected owner-facing command catalog is:

```text
v-docker registry-info PROJECT [json|plain]
v-docker registry-publisher-rotate < age-recipient
v-docker registry-publisher-disable
```

`registry-publisher-rotate` takes no arguments. Bounded stdin is exactly one
native age X25519 recipient, with one optional trailing newline. It rejects
empty input, multiple lines, SSH recipients, plugin recipients, identities,
passphrases, leading/trailing whitespace, control characters, and input over
128 bytes. The accepted form matches:

```text
^age1[ac-hj-np-z02-9]{20,}$
```

Successful stdout is exactly one ASCII-armored age envelope and contains no
status text or JSON wrapper. Failure emits no ciphertext or credential.
Failure messages and audit records use bounded enums only. The caller queries
`registry-info` after success to obtain the actual Harbor-returned publisher
username.

The successful local handoff is:

```bash
set -Eeuo pipefail
umask 077

handoff_dir="$(mktemp -d "${TMPDIR:-/tmp}/vesta-publisher.XXXXXX")"
trap 'rm -rf -- "$handoff_dir"' EXIT HUP INT TERM

age-keygen -o "$handoff_dir/identity.agekey" >/dev/null
age-keygen -y "$handoff_dir/identity.agekey" >"$handoff_dir/recipient.txt"

ssh -- APP_OWNER@<development-fqdn> \
  v-docker registry-publisher-rotate \
  <"$handoff_dir/recipient.txt" \
  >"$handoff_dir/publisher-secret.age"

registry_json="$(ssh -- APP_OWNER@<development-fqdn> \
  v-docker registry-info APP_PROJECT json)"
registry="$(jq -er '.REGISTRY' <<<"$registry_json")"
publisher="$(jq -er '.PUBLISHER_USERNAME' <<<"$registry_json")"

age --decrypt -i "$handoff_dir/identity.agekey" \
  "$handoff_dir/publisher-secret.age" \
  | docker login "$registry" --username "$publisher" --password-stdin
```

Application repositories must wrap this primitive in their own deployment
adapter and use a Docker credential helper or similarly protected local Docker
credential store. They must not print the decrypted stream, save it in shell
history, or retain the ephemeral age identity after login.

## Exact integration permission set

The installation-created system integration robot must use this shape and no
`robot:update`, system `project:update`, user, member, registry-administration,
scanner-administration, replication, garbage-collection, or configuration
permissions:

```json
[
  {
    "kind": "system",
    "namespace": "/",
    "access": [
      {"resource": "project", "action": "create"},
      {"resource": "quota", "action": "read"},
      {"resource": "quota", "action": "update"},
      {"resource": "system-volumes", "action": "read"}
    ]
  },
  {
    "kind": "project",
    "namespace": "*",
    "access": [
      {"resource": "project", "action": "read"},
      {"resource": "robot", "action": "create"},
      {"resource": "robot", "action": "read"},
      {"resource": "robot", "action": "list"},
      {"resource": "robot", "action": "delete"},
      {"resource": "repository", "action": "read"},
      {"resource": "repository", "action": "list"},
      {"resource": "repository", "action": "pull"},
      {"resource": "repository", "action": "push"},
      {"resource": "artifact", "action": "read"}
    ]
  }
]
```

The wildcard repository pull/push permissions exist because Harbor requires a
robot creator's permissions to be a superset of child permissions. They do not
expose the integration credential to tenants. Runtime children receive only
repository pull. Publisher children receive repository pull and push.

Project creation sends only Harbor-supported metadata:

```json
{"project_name":"vx-OWNER","metadata":{"public":"false"}}
```

Vesta owner state, not custom Harbor metadata, remains the ownership
authority. Reconciliation verifies the deterministic namespace, project ID,
private status, operation journal, and Vesta owner mapping. It must not expect
Harbor to persist unsupported `vesta_managed`, `vesta_installation`, or
`vesta_owner` metadata fields.

## Durable rotation state

Upgrade rotation authority to schema 2. Each
`rotations/OWNER-KIND.json` contains only non-secret data:

```json
{
  "SCHEMA": 2,
  "OPERATION_ID": "0123456789abcdef0123456789abcdef",
  "OWNER": "alice",
  "KIND": "runtime",
  "PROJECT_ID": 1,
  "ROBOT_BASENAME": "runtime-0123456789abcdef0123456789abcdef",
  "DESCRIPTION": "vesta-managed:vesta-harbor:alice:runtime:0123456789abcdef0123456789abcdef",
  "PHASE": "prepared",
  "NEW_ROBOT_ID": null,
  "NEW_USERNAME": null,
  "OLD_ROBOT_ID": null,
  "UPDATED_AT": "2026-08-09T00:00:00Z"
}
```

`KIND` is `runtime` or `publisher`. The exact phase sequence is:

```text
prepared
  -> candidate-created
  -> pending-switch
  -> pending-revoke
  -> converged
```

The basename and description are written before POST. A response-loss retry
lists only project robots for the authoritative project ID, filters the exact
Vesta marker and basename, and deletes any candidate whose secret cannot be
recovered. Listing is paginated in bounded pages and fails closed after 1,000
robots instead of silently missing an orphan. It never deletes an unmarked
robot.

Runtime recovery rules:

- `prepared` with no matching robot: retry POST.
- `prepared` with a matching robot but no captured secret: delete that robot,
  verify absence, then retry POST.
- `candidate-created` or `pending-switch` with a valid root-owned candidate
  secret: re-probe and resume the auth switch.
- `candidate-created` or `pending-switch` without the candidate secret: delete
  the candidate and keep the old runtime authority, then start a new rotation.
- `pending-revoke`: verify the new Docker auth and owner mapping before
  idempotently deleting the old robot.
- `converged`: return the recorded new ID/username without creating another
  runtime robot.

Publisher recovery rules:

- No publisher plaintext or ciphertext is placed in the journal.
- If a crash occurs before owner authority switches, delete an inaccessible
  candidate and leave the old publisher active.
- If authority already switched, keep that robot as the current old
  generation, complete old-generation deletion, and require the next explicit
  rotate invocation to create a deliverable generation.
- If ciphertext generation, stdout delivery, SSH transport, or local
  decryption fails, the tenant reruns rotation. A successful subsequent
  rotation replaces the inaccessible generation without administrator
  intervention.
- The remote command emits ciphertext only after the new authority is durable
  and old-robot deletion has converged. A local adapter must capture the whole
  encrypted response and require SSH exit 0 before decrypting it.

Delete treats Harbor 200 and 404 as idempotent success only after the requested
ID and Vesta marker have been validated. Other statuses remain typed failures.
Robot creation conflicts, duplicate markers, unexpected robot level/project,
unexpected permissions, changed expiry, malformed generated secrets, and
unexpected response keys fail closed.

---

## Milestone 1: Encode real Harbor behavior

### Task 1: Replace the incompatible credential contract

**Files:**

- Modify: `.docs/contracts/harbor-provider.md`
- Modify: `.docs/contracts/compose-shell-access.md`
- Modify: `.docs/specs/2026-08-08-vesta-managed-harbor-registry.md`
- Modify: `.docs/validation/2026-08-08-vesta-managed-harbor-development.md`
- Modify: `test/harbor/test-doc-contract.sh`
- Modify: `test/test_compose_docs.sh`

- [ ] **Step 1: Write failing documentation-contract assertions**

Assert the new `registry-publisher-rotate < age-recipient` interface, generated
secret ownership, project-level child robots, age ciphertext-only output,
create/delete rotation, and production deferral. Assert the old command and
caller-generated secret contract are absent.

Run:

```bash
bash test/harbor/test-doc-contract.sh
bash test/test_compose_docs.sh
```

Expected: both fail because the current contracts still require
`registry-publisher-change < publisher-secret`.

- [ ] **Step 2: Update the contract and specification**

Include the upstream commit-pinned evidence, exact integration permissions,
schema-2 journal, runtime persistence boundary, publisher age handoff,
deletion semantics, response-loss handling, and no routine bootstrap-admin
use. Mark the former contract as superseded by this correction rather than
silently rewriting development evidence.

- [ ] **Step 3: Update the blocker evidence**

Keep the original failed acceptance facts intact. Append the selected
source-validated resolution and state that development acceptance remains
incomplete until this plan's final milestone passes.

- [ ] **Step 4: Run the focused contract tests**

Run:

```bash
bash test/harbor/test-doc-contract.sh
bash test/test_compose_docs.sh
git diff --check
```

Expected: all exit 0.

- [ ] **Step 5: Commit the contract correction**

```bash
git add .docs/contracts/harbor-provider.md \
  .docs/contracts/compose-shell-access.md \
  .docs/specs/2026-08-08-vesta-managed-harbor-registry.md \
  .docs/validation/2026-08-08-vesta-managed-harbor-development.md \
  test/harbor/test-doc-contract.sh test/test_compose_docs.sh
git commit -m "docs(harbor): adopt generated robot credentials"
```

### Task 2: Make the fake Harbor API enforce v2.15 behavior

**Files:**

- Modify: `test/harbor/fixtures/fake-harbor-api.py`
- Modify: `test/harbor/test-fixtures.sh`
- Modify: `test/harbor/test-api.sh`
- Add: `test/harbor/test-upstream-robot-contract.sh`
- Modify: `test/harbor/run-focused.sh`

- [ ] **Step 1: Add failing parity tests**

Cover these exact behaviors:

1. `POST /api/v2.0/robots` ignores any submitted `secret`, generates a valid
   different secret, returns it once, and stores no recoverable plaintext in
   later GET/list responses.
2. Project robot names are returned with the configured prefix and
   `PROJECT+ROBOT_BASENAME` form.
3. A system robot with wildcard project permissions can create a project
   robot only with a permission subset.
4. Integration identity `PATCH` refresh and `PUT` update return 403 because it
   has no robot update permission.
5. Integration identity GET/list/create/delete for project robots succeeds
   with exact scope.
6. Delete followed by delete produces 200 then 404.
7. Project creation persists only supported metadata and defaults private.
8. A simulated lost create response leaves a discoverable marked candidate.

Run:

```bash
bash test/harbor/test-upstream-robot-contract.sh
bash test/harbor/test-api.sh
```

Expected: failures against the current caller-secret fixture.

- [ ] **Step 2: Implement permission-aware fixture identities**

Make the fixture distinguish bootstrap administrator, Vesta integration
robot, runtime child, and publisher child. Store generated fixture secrets
only inside the isolated test-state file, redact every response after create,
and model project IDs, robot levels, descriptions, prefixes, permissions,
expiry, 403 update, and idempotent 404 deletion.

- [ ] **Step 3: Add source-parity assertions**

The new test must include comments naming the Harbor v2.15.0 source paths and
commit above. It is a behavioral fixture test, not a network clone/download
test; release verification remains offline and pinned.

- [ ] **Step 4: Run fixture validation**

```bash
python3 -m py_compile test/harbor/fixtures/fake-harbor-api.py
bash test/harbor/test-fixtures.sh
bash test/harbor/test-upstream-robot-contract.sh
bash test/harbor/test-api.sh
git diff --check
```

Expected: all exit 0 and no test output contains a generated secret canary.

- [ ] **Step 5: Commit fixture parity**

```bash
git add test/harbor/fixtures/fake-harbor-api.py \
  test/harbor/test-fixtures.sh test/harbor/test-api.sh \
  test/harbor/test-upstream-robot-contract.sh test/harbor/run-focused.sh
git commit -m "test(harbor): model generated robot secrets"
```

### Milestone 1 review

- [x] Review the contract against the pinned Harbor source paths.
- [x] Verify no contract says Harbor accepts a creation secret or delegates
  robot update.
- [x] Run `bash test/harbor/run-focused.sh` once.
- [x] Do not proceed if the fixture can pass caller-selected secrets,
  integration refresh/update, or unmarked orphan deletion.

### Milestone 1 record — completed 2026-08-09

- Completed behavior: source-backed generated one-time secrets, project-level
  delegated children, create/delete credential lifecycle, strict native age
  recipient contract, delete/404 parity, and the exact Harbor distinction
  between its advertised project quota-read permission and its system-scoped
  quota endpoint.
- Commits: `81765e53`, `9f02a520`, `335a5d2b`, `d48cc60e`, `5940c634`, and
  `10b4072f`.
- Focused evidence: Python fixture compilation; fixture, upstream robot
  contract, protected API, documentation contract, and Compose documentation
  tests; `git diff --check`; complete `test/harbor/run-focused.sh` pass after
  authorization changes.
- Specification result: approved after the five numbered source-parity
  blockers and the direct quota-catalog regression were corrected.
- Deferred by dependency: broker command migration and tenant-guide/runbook
  examples remain owned by Milestones 3 and 4; the Compose documentation test
  keeps the current broker command until that atomic migration.
- Next milestone: correct the protected API adapter and install a generated,
  least-privilege Harbor integration identity.

---

## Milestone 2: Correct installation and the Harbor adapter

### Task 3: Add a secret-bearing API path that never writes publisher plaintext

**Files:**

- Modify: `func/vx/harbor/api.sh`
- Modify: `func/vx/harbor/main.sh`
- Modify: `func/vx/harbor/status.sh`
- Modify: `test/harbor/test-api.sh`
- Modify: `test/harbor/test-host-boundary.sh`
- Modify: `test/harbor/test-status.sh`

- [ ] **Step 1: Write failing protected-adapter tests**

Assert that:

- generic `_vx_harbor_api_call` cannot POST robot creation;
- generated robot creation sends no `secret` property;
- the secret-bearing response remains in pipes/shell-local memory and never
  appears in `.api-response.*`, `.robot-body.*`, `.probe-curl.*`, audit output,
  process argv, or environment;
- the create response has exact keys and a valid generated secret;
- project robot list/get/create/delete enforce project ID, level, marker,
  actual returned username, and permission shape;
- credential probing feeds a temporary curl configuration through stdin via
  `--config -`, not a file or `--user` argument;
- list pagination stops at 1,000 entries and fails on duplicates.

- [ ] **Step 2: Split redacted and secret-bearing API calls**

Retain the current protected-file response path for APIs that cannot return
secrets. Add a narrowly named internal robot-create helper that:

1. uses the protected integration curl config and Unix socket;
2. captures body plus HTTP status in process memory with a one-MiB bound;
3. validates status 201 and the exact `RobotCreated` schema;
4. validates `expires_at == -1`, returned project-level name, and Harbor secret
   policy;
5. returns secret-bearing JSON only to the trusted lifecycle caller;
6. unsets local body/secret variables on every branch.

Do not pass response JSON through `_vx_harbor_api_failure`, command tracing,
or audit helpers.

- [ ] **Step 3: Replace the robot API surface**

Implement:

```text
vx_harbor_api_project_robots PROJECT_ID
vx_harbor_api_robot_create_generated PROJECT PROJECT_ID BASENAME KIND MARKER
vx_harbor_api_robot_get PROJECT_ID ROBOT_ID
vx_harbor_api_robot_delete PROJECT_ID ROBOT_ID MARKER
vx_harbor_api_credential_probe USERNAME < secret
```

Remove `vx_harbor_api_robot_disable` and caller-secret input from robot create.
Create children with `level:"project"`; runtime access is pull, publisher
access is pull+push.

Remove the unused all-projects list adapter and its corresponding system
`project:list` permission. Update the local API guard to allow only the bounded,
encoded project-robot list query needed for marked-candidate recovery.

- [ ] **Step 4: Correct project creation authority**

Send only `metadata.public:false`. Remove the unused project-update adapter and
verify private status through GET. Treat Vesta's owner mapping plus a prepared
operation as authority; reject pre-existing unowned namespace collisions.

- [ ] **Step 5: Validate the adapter**

```bash
bash -n func/vx/harbor/api.sh func/vx/harbor/main.sh \
  func/vx/harbor/status.sh
bash test/harbor/test-api.sh
bash test/harbor/test-host-boundary.sh
bash test/harbor/test-status.sh
git diff --check
```

Expected: all exit 0; the secret canary is absent from the test root, command
line capture, environment capture, stdout other than the explicitly trusted
create caller, and audit log.

- [ ] **Step 6: Commit the API correction**

```bash
git add func/vx/harbor/api.sh func/vx/harbor/main.sh \
  func/vx/harbor/status.sh test/harbor/test-api.sh \
  test/harbor/test-host-boundary.sh test/harbor/test-status.sh
git commit -m "fix(harbor): consume generated robot secrets"
```

### Task 4: Build a valid least-privilege integration identity

**Files:**

- Modify: `func/vx/harbor/install.sh`
- Modify: `func/vx/harbor/state.sh`
- Modify: `func/vx/harbor/authority-schema.py`
- Modify: `test/harbor/test-install.sh`
- Modify: `test/harbor/test-state.sh`

- [ ] **Step 1: Write failing install tests**

Reject integration bodies containing caller-selected `secret`,
`project:update` at system scope, or `robot:update`. Require the exact two-scope
permission set in this plan. Simulate create-response loss, malformed generated
secret, integration probe failure, old-integration replacement, rollback, and
retry.

- [ ] **Step 2: Create the integration secret from Harbor's response**

POST without a secret. Capture the returned actual username and generated
secret in memory, write only `secrets/.integration.curl.candidate` as root
0600, probe it, then atomically replace `secrets/integration.curl`. Journals
contain IDs, returned usernames, permission version, and markers only.

- [ ] **Step 3: Make installation replacement crash-safe**

Write the candidate basename/marker before POST. If POST may have succeeded
without a usable response, find and delete only the exact marked candidate via
bootstrap administrator, then retry. Keep the prior integration identity until
the candidate passes all probes. After the credential file switches, delete
the prior integration robot with bootstrap authority. On rollback, restore the
prior curl file and robot/configuration state; never attempt a robot update.

- [ ] **Step 4: Probe delegated operations, not just catalog strings**

During administrator-owned installation, create a disposable private project,
create a project-level pull child through the integration robot, authenticate
the child, list/get/delete it through the integration robot, and verify 403 for
refresh/update. Clean the disposable project with bootstrap administrator.
Any cleanup failure aborts installation and leaves a resumable journal.

- [ ] **Step 5: Add age prerequisites**

Require fixed `/usr/bin/age` and `/usr/bin/age-keygen` along with the existing
Harbor prerequisites. Do not search caller PATH during privileged execution.

- [ ] **Step 6: Run focused installation tests**

```bash
bash -n func/vx/harbor/install.sh func/vx/harbor/state.sh
python3 func/vx/harbor/authority-schema.py --help >/dev/null 2>&1 || test $? -eq 1
bash test/harbor/test-state.sh
bash test/harbor/test-install.sh
git diff --check
```

Expected: all test scripts exit 0; direct schema invocation rejects missing
arguments without a traceback.

- [ ] **Step 7: Commit integration identity correction**

```bash
git add func/vx/harbor/install.sh func/vx/harbor/state.sh \
  func/vx/harbor/authority-schema.py \
  test/harbor/test-install.sh test/harbor/test-state.sh
git commit -m "fix(harbor): delegate valid project robot authority"
```

### Milestone 2 review

- [ ] Compare the emitted integration body field-for-field with this plan.
- [ ] Search all shipped Harbor code for `robot:update`, caller-supplied robot
  secrets, and `vx_harbor_api_robot_disable`; only historical validation text
  may still describe the failed behavior.
- [ ] Run `bash test/harbor/run-focused.sh` once.
- [ ] Do not proceed unless install rollback preserves the prior integration
  identity and cleans an unknown-secret candidate after response loss.

---

## Milestone 3: Implement generated runtime and publisher credentials

### Task 5: Upgrade the rotation journal and runtime pull lifecycle

**Files:**

- Modify: `func/vx/harbor/authority-schema.py`
- Modify: `func/vx/harbor/credentials.sh`
- Modify: `func/vx/harbor/owners.sh`
- Modify: `func/vx/harbor/backup.sh`
- Modify: `test/harbor/test-credentials.sh`
- Modify: `test/harbor/test-owner-reconcile.sh`
- Modify: `test/harbor/test-backup.sh`

- [ ] **Step 1: Write failing schema-2 and recovery tests**

Test every phase and crash boundary: before POST, response loss, after create,
after candidate secret staging, after probe, after journal write, after Docker
auth switch, before candidate unlink, before old delete, after 404 old delete,
and after convergence. Test duplicate markers and missing/wrong-mode candidate
files.

- [ ] **Step 2: Write `prepared` before robot creation**

Generate the 32-hex operation ID once. Derive `runtime-$operation` and the
exact Vesta marker. Persist schema 2 with authoritative project ID, then POST.
Use the Harbor-returned ID, username, and secret. Do not call Vesta's random
secret helper.

- [ ] **Step 3: Stage and verify the generated runtime secret**

Write the runtime candidate under the owner's registry root as root-owned
0600, probe the returned username/secret, update the journal, and switch
`config.json` plus redacted `registries.json` atomically. The durable Docker
config is the only plaintext-equivalent runtime credential store.

- [ ] **Step 4: Implement phase-aware recovery**

Follow the runtime recovery table above. Validate marker, project ID, level,
permissions, and returned username before deleting any candidate or old robot.
Keep old credentials usable until the new auth is proven and authority has
switched.

- [ ] **Step 5: Update backup schemas**

Accept only rotation schema 2 in new backups. Publisher journals contain no
secret or ciphertext. Runtime candidate files remain in the separately age-
encrypted secret payload when present during an interrupted rotation. Restore
validation rejects a journal/candidate mismatch.

- [ ] **Step 6: Validate runtime lifecycle**

```bash
bash -n func/vx/harbor/credentials.sh func/vx/harbor/owners.sh \
  func/vx/harbor/backup.sh
bash test/harbor/test-credentials.sh
bash test/harbor/test-owner-reconcile.sh
bash test/harbor/test-backup.sh
git diff --check
```

Expected: all exit 0; each injected crash resumes or safely replaces the
candidate without creating an unmarked orphan or exposing the secret.

- [ ] **Step 7: Commit runtime lifecycle**

```bash
git add func/vx/harbor/authority-schema.py \
  func/vx/harbor/credentials.sh func/vx/harbor/owners.sh \
  func/vx/harbor/backup.sh test/harbor/test-credentials.sh \
  test/harbor/test-owner-reconcile.sh test/harbor/test-backup.sh
git commit -m "fix(harbor): rotate generated runtime credentials"
```

### Task 6: Replace publisher change with encrypted publisher rotation

**Files:**

- Delete: `bin/v-change-user-harbor-registry-publisher`
- Add: `bin/v-rotate-user-harbor-registry-publisher`
- Modify: `bin/v-run-user-docker-command`
- Modify: `func/vx/harbor/publisher.sh`
- Modify: `func/vx/harbor/credentials.sh`
- Modify: `func/vx/harbor/authority-schema.py`
- Modify: `test/harbor/test-publisher.sh`
- Modify: `test/compose/fixtures/shell-broker-namespace.sh`

- [ ] **Step 1: Write failing broker and publisher tests**

Require `registry-publisher-rotate`, bounded recipient stdin, no arguments,
owner derivation from kernel/sudo state, fixed `/usr/bin/age`, exact armored
ciphertext stdout, and no success status line. Reject the former command.
Exercise every journal phase, lost response, failed probe, failed age
encryption, failed state switch, old-delete outage, output failure, retry after
an inaccessible successful generation, and publisher-disable interaction.

- [ ] **Step 2: Implement bounded native-age recipient parsing**

Use the broker's protected snapshot mechanism with a 128-byte limit and a
recipient-specific snapshot class. Validate exactly one native recipient.
Never accept an age identity or publisher password from the remote caller.

- [ ] **Step 3: Implement publisher rotation**

Create a project-level pull+push robot from a prepared journal, capture and
probe Harbor's generated secret in memory, produce armored age ciphertext in
memory, switch owner authority, delete the old robot, write converged state,
audit only enums/IDs, then write the ciphertext to stdout. Unset secret-bearing
variables immediately after encryption.

- [ ] **Step 4: Preserve deterministic retry semantics**

A failed command returns no usable result. If a generation became current but
its envelope was not delivered, the next invocation treats it as the old
generation and replaces it. Do not try to recover or display its secret.

- [ ] **Step 5: Keep the public adapter machine-safe**

`v-rotate-user-harbor-registry-publisher` must not call `printf
publisher-ready`, wrap output in JSON, or mix Vesta status messages into
stdout. Success is indicated by exit 0 plus a syntactically valid age envelope.
Failures use the existing Vesta error path on stderr and nonzero exit.

- [ ] **Step 6: Validate publisher lifecycle**

```bash
bash -n bin/v-rotate-user-harbor-registry-publisher \
  bin/v-run-user-docker-command func/vx/harbor/publisher.sh \
  func/vx/harbor/credentials.sh
bash test/harbor/test-publisher.sh
bash test/compose/fixtures/shell-broker-namespace.sh
git diff --check
```

Expected: all exit 0; test canaries are absent from process captures, Vesta
state, temporary files, audit, logs, and non-encrypted stdout.

- [ ] **Step 7: Commit encrypted publisher rotation**

```bash
git add bin/v-run-user-docker-command \
  bin/v-rotate-user-harbor-registry-publisher \
  func/vx/harbor/publisher.sh func/vx/harbor/credentials.sh \
  func/vx/harbor/authority-schema.py test/harbor/test-publisher.sh \
  test/compose/fixtures/shell-broker-namespace.sh
git rm bin/v-change-user-harbor-registry-publisher
git commit -m "feat(harbor): encrypt generated publisher handoff"
```

### Milestone 3 review

- [ ] Trace a runtime secret from Harbor response to the encrypted backup and
  verify every durable copy is required and mode 0600.
- [ ] Trace a publisher secret and verify it exists only in Harbor's create
  response, process memory/pipes, and tenant-decrypted Docker login stdin.
- [ ] Verify no bootstrap-admin call is reachable from the tenant command.
- [ ] Run `bash test/harbor/run-focused.sh` once.
- [ ] Do not proceed if direct plaintext output, a secret temp file, refresh,
  update, or system-level child robot remains.

---

## Milestone 4: Make all revocation and user surfaces consistent

### Task 7: Replace robot disable/update with idempotent deletion everywhere

**Files:**

- Modify: `func/vx/harbor/publisher.sh`
- Modify: `func/vx/harbor/credentials.sh`
- Modify: `func/vx/harbor/owners.sh`
- Modify: `func/vx/harbor/disable.sh`
- Modify: `func/vx/harbor/health.sh`
- Modify: `test/harbor/test-revocation.sh`
- Modify: `test/harbor/test-disable.sh`
- Modify: `test/harbor/test-health.sh`

- [ ] **Step 1: Write failing revocation-order tests**

Cover publisher disable, package registry quota to zero, Docker project
entitlement removal, owner suspension, owner deletion, provider disablement,
Harbor outage, 404 retry, and restart recovery. Require publisher deletion
before runtime deletion and credential deletion before authority reports it
disabled.

- [ ] **Step 2: Delete credentials without deleting artifacts**

For publisher disable, delete the publisher child, verify absence, then clear
publisher fields and set `publisher-disabled` or `retained`. For runtime
revocation, delete the runtime child before removing Vesta's local pull auth.
For owner deletion, preserve a tombstone until both deletes and local auth
scrub converge. Never delete the Harbor project or repository data in these
paths.

- [ ] **Step 3: Correct provider disablement**

Delete every publisher child, then every runtime child, preserving retryable
operations. During this administrator-owned transaction, revoke the system
integration robot with bootstrap authority and scrub active integration curl
credentials only after child deletion and backup/rollback evidence are safe.
Then remove ingress and stop the provider. Re-enable/install creates a fresh
integration secret from Harbor.

- [ ] **Step 4: Keep health redacted**

Health verifies child existence, level, project ID, marker, and enabled state
without returning permission arrays, creator data, usernames beyond the
already approved publisher discovery field, or any credential.

- [ ] **Step 5: Validate revocation**

```bash
bash -n func/vx/harbor/publisher.sh func/vx/harbor/credentials.sh \
  func/vx/harbor/owners.sh func/vx/harbor/disable.sh \
  func/vx/harbor/health.sh
bash test/harbor/test-revocation.sh
bash test/harbor/test-disable.sh
bash test/harbor/test-health.sh
git diff --check
```

Expected: all exit 0; outage leaves a bounded retryable journal and does not
mutate workloads, routes, firewall, or retained artifacts.

- [ ] **Step 6: Commit deletion-based revocation**

```bash
git add func/vx/harbor/publisher.sh func/vx/harbor/credentials.sh \
  func/vx/harbor/owners.sh func/vx/harbor/disable.sh \
  func/vx/harbor/health.sh test/harbor/test-revocation.sh \
  test/harbor/test-disable.sh test/harbor/test-health.sh
git commit -m "fix(harbor): revoke robot credentials by deletion"
```

### Task 8: Update tenant, operator, panel, and package documentation

**Files:**

- Modify: `.docs/user-guides/vesta-managed-harbor.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`
- Modify: `docs/container-orchestration.md`
- Modify: `.docs/README.md`
- Modify: `web/templates/docker_list_shared.php`
- Modify: `web/ajax/docker/actions/harbor_publisher.php`
- Modify: `test/harbor/test-doc-contract.sh`
- Modify: `test/test_harbor_panel.php`

- [ ] **Step 1: Write failing documentation and panel tests**

Require generated secrets, the age handoff commands, returned username lookup,
local Docker credential helper guidance, deletion-based disablement, runtime
credential continuity, and retry behavior after loss. Reject every old
caller-generated secret command and any claim that Harbor/Vesta can recover a
publisher secret.

- [ ] **Step 2: Update the canonical tenant guide**

Provide the exact safe command sequence from this plan followed by build,
temporary versioned push, digest resolution, Compose digest reference,
`v-docker` preview/pull/apply/deploy, health/readiness/revision/drift evidence,
rollback, and publisher disablement. Keep application examples generic and
leave repository-specific caveats in consuming repositories.

- [ ] **Step 3: Explain the lifecycle in plain language**

State that Harbor creates the password once; Vesta encrypts the publisher copy
to the tenant and cannot show it again; rerunning rotation replaces a lost
credential; disabling publishing deletes only the push credential; runtime
pulls continue through a different Vesta-managed credential; package downgrade
or suspension revokes access without deleting images.

- [ ] **Step 4: Correct panel language**

The panel remains redacted and disable-only. It may report current publisher
enabled state and link to CLI instructions. It must not accept an age identity,
recipient, robot name, or secret through HTML/AJAX.

- [ ] **Step 5: Validate docs and panel**

```bash
bash test/harbor/test-doc-contract.sh
bash test/test_compose_docs.sh
php -l web/ajax/docker/actions/harbor_publisher.php
php -l web/templates/docker_list_shared.php
php test/test_harbor_panel.php
git diff --check
```

Expected: all exit 0; links resolve; old publisher-change syntax is absent from
active contracts/guides/code.

- [ ] **Step 6: Commit user-surface correction**

```bash
git add .docs/user-guides/vesta-managed-harbor.md \
  DOCKER_ORCHESTRATION_DEPLOYMENT.md docs/container-orchestration.md \
  .docs/README.md web/templates/docker_list_shared.php \
  web/ajax/docker/actions/harbor_publisher.php \
  test/harbor/test-doc-contract.sh test/test_harbor_panel.php
git commit -m "docs(harbor): document encrypted publisher rotation"
```

### Milestone 4 review

- [x] Search active code/docs/tests for
  `registry-publisher-change`, `v-change-user-harbor`,
  `vx_harbor_api_robot_disable`, and caller-generated publisher secret text.
- [x] Confirm remaining matches exist only in historical evidence explicitly
  labelled as superseded.
- [x] Run `bash test/harbor/run-focused.sh` once.
- [x] Do not proceed if panel or docs can collect/display a credential.

---

## Milestone 5: Focused release validation and development acceptance

### Task 9: Run the bounded local release gate

**Files:**

- Modify only if defects are found in files already owned by Tasks 1–8.

- [ ] **Step 1: Run touched syntax and focused Harbor tests**

```bash
bash -n bin/v-rotate-user-harbor-registry-publisher \
  bin/v-run-user-docker-command func/vx/harbor/*.sh
python3 -m py_compile func/vx/harbor/authority-schema.py \
  test/harbor/fixtures/fake-harbor-api.py
php -l web/ajax/docker/actions/harbor_publisher.php
php -l web/templates/docker_list_shared.php
bash test/harbor/run-focused.sh
git diff --check
```

Expected: all exit 0.

- [ ] **Step 2: Run the repository-owned limited launcher once**

```bash
bash test/compose/run-production-readiness-limited.sh
```

Expected: exit 0. Do not invoke broad ShellCheck, the canonical full gate
directly, or set `VX_READINESS_ALLOW_UNLIMITED=yes`.

- [ ] **Step 3: Run secret-surface scans**

Use deterministic test canaries and inspect the isolated test root, command
captures, process capture fixtures, audit, logs, backup manifest, HTML, and Git
diff. Search active surfaces for removed APIs:

```bash
rg -n 'registry-publisher-change|v-change-user-harbor|robot:update|vx_harbor_api_robot_disable' \
  bin func web install test docs .docs DOCKER_ORCHESTRATION_DEPLOYMENT.md
git diff --check
```

Expected: no active implementation/guide match; historical blocker evidence
may retain clearly contextualized matches.

- [ ] **Step 4: Commit any bounded test correction**

Use a focused commit only if validation exposed a defect. Stage only the exact
paths already listed in Tasks 1–8, inspect the staged diff, and commit with
`test(harbor): close credential lifecycle gate`. Do not create this commit when
no files changed.

### Task 10: Complete development-host acceptance without workload mutation

**Files:**

- Modify: `.docs/validation/2026-08-08-vesta-managed-harbor-development.md`

- [ ] **Step 1: Enforce DNS and TLS prerequisites**

From the deployment client, require `<development-fqdn>` to resolve to the
authorized development address `<development-host>` and require the panel
certificate chain and hostname to validate with the system trust store. Do not
use an IP as TLS identity, `--insecure`, an insecure Docker registry, or a
permanent hosts-file bypass. If either prerequisite fails, leave the provider
disabled and record the external blocker.

- [ ] **Step 2: Stage one exact successor transaction**

Stage control-plane files to `operator@<development-fqdn>` over the authorized
SSH key, capture exact commit/archive hashes and prior bytes, and create a
root-owned mode-0700 rollback. Scope is Harbor control plane and disposable
registry probe state only. Preserve the currently serving tenant container,
its desired state, image, network, volumes, routes, revision, and credentials.

- [ ] **Step 3: Install and verify provider authority**

Run the transactional Harbor installer. Verify ten healthy internal
containers, protected Unix sockets, no Harbor host TCP listener, exact panel
ingress routes, managed provider state, valid integration permissions, and no
bootstrap credential use by routine API calls.

- [ ] **Step 4: Exercise an eligible disposable owner**

Create or use a development-only Vesta test owner with nonzero
`DOCKER_PROJECTS` and `DOCKER_REGISTRY_MB`. Do not alter a production-client
owner. Verify private project/quota convergence and distinct project-level
runtime/publisher robots.

- [ ] **Step 5: Exercise publisher delivery end to end**

As the disposable owner:

1. query redacted `registry-info`;
2. create an ephemeral age identity locally;
3. rotate the publisher through `v-docker` and capture ciphertext;
4. require SSH exit 0;
5. decrypt directly into `docker login --password-stdin`;
6. build an offline `FROM scratch` probe image;
7. push one versioned tag;
8. resolve its immutable digest;
9. verify the integration API and runtime robot can read/pull only the expected
   project digest;
10. verify another owner cannot list, pull, push, rotate, or discover it.

Do not create or deploy an application workload in this acceptance.

- [ ] **Step 6: Exercise loss, rotation, and revocation**

Rotate again and prove the first publisher credential fails while runtime
pulls continue. Simulate one response-loss recovery using the fixture-backed
checkpoint on the staged code, then verify no marked orphan remains. Disable
publishing and prove push fails, runtime digest pull still succeeds, artifacts
remain, and `registry-info` is redacted and accurate.

- [ ] **Step 7: Exercise entitlement and outage boundaries**

Set only the disposable owner's registry entitlement to zero and verify both
children are revoked, local runtime auth is scrubbed, artifacts remain, and no
workload changes. Restore entitlement and verify fresh generated credentials.
Stop only the Harbor service to prove outage isolation, then resume it and
converge. Do not alter firewall, routes, DNS, or unrelated packages.

- [ ] **Step 8: Validate backup and administrative disable**

Create an encrypted backup, run validate-only restore, and verify publisher
plaintext is absent while required runtime/integration recovery secrets exist
only inside the encrypted secret payload. Exercise the disable plan and token,
verify child and integration credential revocation order, retained artifacts,
ingress removal, no host listener, and stable stopped/disabled state. Re-enable
only if the accepted development endpoint is intended to remain operational;
otherwise close in the documented disabled state.

- [ ] **Step 9: Update acceptance evidence**

Append exact commit, archive hash, rollback path, commands, statuses, redacted
robot IDs/usernames, project/quota observations, pushed digest, revocation
results, backup ID/hash, provider final state, and unchanged tenant workload
hash. Never record a secret, age identity, ciphertext body, Docker auth, or
production credential.

- [ ] **Step 10: Commit acceptance evidence**

```bash
git add .docs/validation/2026-08-08-vesta-managed-harbor-development.md
git commit -m "docs(harbor): record generated credential acceptance"
```

### Final review and release decision

- [ ] Confirm every active child robot is project-level and exactly owner
  scoped.
- [ ] Confirm the integration robot has the exact permission set in this plan
  and no update/admin privilege.
- [ ] Confirm Vesta owns only integration/runtime durable secrets and no
  publisher plaintext.
- [ ] Confirm all revocation paths use validated delete, never robot update.
- [ ] Confirm the serving development tenant workload is byte-for-byte and
  runtime-identity unchanged.
- [ ] Confirm production was neither contacted nor changed.
- [ ] Confirm `git status --short` is clean and record final commit hashes.

## Completion criteria

This plan is complete only when all of the following are true:

1. Stock Harbor v2.15 creates every integration/runtime/publisher secret.
2. No active Vesta path submits a robot creation secret or requires
   `robot:update`.
3. Routine operations use only the least-privilege integration robot;
   bootstrap administrator use is confined to explicit administrator-owned
   provider lifecycle operations.
4. Runtime pull credentials survive restart and encrypted backup/restore.
5. Publisher plaintext is never durable on Vesta and is delivered only as age
   ciphertext to the requesting owner.
6. A lost publisher credential is recoverable by tenant-triggered replacement,
   without Debian approval or Harbor administration.
7. Rotation and response-loss recovery leave at most one authoritative current
   robot per owner/kind and no unmarked deletion behavior.
8. Publisher disable, entitlement loss, suspension, owner deletion, and
   provider disable revoke credentials in deterministic order while retaining
   OCI artifacts unless a separate destructive action is explicitly approved.
9. Focused Harbor tests and the limited readiness launcher pass.
10. Development acceptance passes with DNS/TLS trust, immutable push/pull,
    isolation, revocation, backup validation, and unchanged serving workloads.
11. Production remains deferred.

## Implementation handoff

Execute milestone by milestone. At each boundary, use a fresh security reviewer
to compare code, fixture behavior, authority schemas, tests, and active docs to
this plan and the pinned Harbor sources. Stop a milestone only on a concrete
failed acceptance condition; do not replace the design with broader Harbor
permissions, bootstrap-admin rotation, plaintext output, raw Docker access, or
an unreviewed registry path.
