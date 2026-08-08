# Vesta-Managed Harbor Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `$milestone-driven-implementation`. This is one integrated security product,
> so implementation proceeds through five product milestones with one
> specification/security review at each milestone boundary. Run touched syntax
> and task-owned focused tests while building, run `test/harbor/run-focused.sh`
> once per milestone, and reserve the limited production-readiness launcher for
> release closure. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a pinned Harbor registry an optional Vesta-managed service so
eligible Docker tenants can publish images and deploy immutable digests through
`v-docker` without administering Harbor or receiving raw Docker access.

**Architecture:** Vesta desired state is authoritative. A root-owned Harbor
provider uses a protected Unix socket and exact `/v2/` and `/service/token`
routes on Vesta's existing hostname, TLS certificate, and panel port; Harbor
has no host TCP listener. Owner reconciliation converges deterministic Harbor
projects, quotas, separate runtime and publisher credentials, observations,
revocation, and shell access toward Vesta package state using small durable
pending-operation journals and idempotent operation IDs.

**Tech Stack:** Bash, Vesta flat-file authority, Harbor v2.15.0, Docker Compose
v2, OCI Distribution and Harbor REST APIs, nginx, systemd, curl, jq, Cosign,
age, PHP, focused Bash/PHP/Python fixtures, and the repository-owned
resource-limited readiness launcher.

---

## Scope and release rules

Production deployment is explicitly deferred. Development acceptance may
mutate only the authorized development host and must preserve rollback
evidence. No task may run broad standalone ShellCheck, the unlimited readiness
gate, or the canonical full gate directly.

The five product milestones are:

1. Disabled provider authority and package entitlement.
2. Verified transactional installation and shared TLS ingress.
3. Owner isolation, quota, credentials, publisher lifecycle, and discovery.
4. Health, backup validation, disable lifecycle, panel essentials, and docs.
5. Development acceptance and release closeout.

The fixed security boundaries are:

- Harbor release artifacts are pinned by digest and verified by signature.
- Tenants receive neither raw Docker/socket/group access nor Harbor
  administration.
- Harbor has no host TCP listener. Public registry traffic uses Vesta's
  authoritative FQDN, existing TLS port/certificate, and exact paths; local
  administration uses a protected Unix socket.
- Secrets never enter argv, environment, logs, HTML, metadata, audit records,
  or unencrypted backups.
- Owner identity is derived from kernel/Vesta state. Projects, quotas, and
  credentials are owner-scoped; runtime and publisher credentials are
  separate and independently revoked.
- Installation and ingress changes are transactional. Provider outage does
  not mutate tenant workloads, routes, firewall, or package authority.
- Backup ciphertext and restore validation are required for first release.
- Ordinary image references remain immutable digest references.

## Fixed interfaces and state

Administrator commands:

```text
v-install-harbor-registry
v-list-harbor-registry [json|plain]
v-list-harbor-registry-owners [json|plain]
v-sync-harbor-registry-owner USER
v-sync-harbor-registry-owners
v-backup-harbor-registry
v-restore-harbor-registry BACKUP_ID validate
v-plan-disable-harbor-registry [json|plain]
v-disable-harbor-registry CONFIRMATION_TOKEN
```

Owner-derived shell commands:

```text
v-docker registry-info PROJECT [json|plain]
v-docker registry-publisher-change < publisher-secret
v-docker registry-publisher-disable
```

No interface accepts caller-supplied owner, registry host/port, Harbor URL,
project ID, permissions, secret path, archive path, Docker options, or workload
mutation instructions.

Root-owned authority:

```text
/usr/local/vesta/data/harbor/
  provider.json
  owners/<owner>.json
  observations/provider.json
  observations/<owner>.json
  operations/<owner>.json
  secrets/bootstrap.curl
  secrets/integration.curl
  secrets/backup.agekey
  backup-recipient.txt
  release/
  backups/
  locks/provider.lock
/var/lib/vesta-harbor/
/usr/local/vesta/nginx/conf/harbor-registry.conf
/etc/systemd/system/vesta-harbor.service
/run/vesta-harbor/proxy.sock
```

Provider and secret directories are root-owned `0700`. Authority, secret,
mapping, observation, operation, and rendered configuration files are regular,
single-link, non-symlink, root-owned `0600`. Provider lock order is:

```text
provider shared/exclusive -> owner access -> owner registry -> tenant project
```

No Harbor API call is made while a tenant project lock is held.

## Transaction and convergence model

Vesta package and user state is desired authority. A package change writes the
new entitlement through the existing Vesta command and records, before Harbor
mutation, one bounded root-owned pending operation:

```json
{
  "SCHEMA": 1,
  "OPERATION_ID": "random-idempotency-id",
  "OWNER": "derived-owner",
  "DESIRED_PACKAGE": "package-name",
  "DESIRED_REGISTRY_MB": "0|integer|unlimited",
  "STATE": "pending|converged|failed",
  "ATTEMPTS": 0,
  "LAST_ERROR": null,
  "CREATED_AT": 0,
  "UPDATED_AT": 0
}
```

Reconciliation idempotently moves Harbor quota and Compose shell access
forward toward that desired state. Interruption leaves `pending`; restart or
the next owner reconciliation resumes the same operation ID. A terminal,
bounded retry failure records `failed`. Conflicting package changes are
blocked while an operation is `pending` or `failed`; an administrator can
retry reconciliation after correcting the cause. No HMAC transition token,
whole-file preimage, atomic-exchange/CAS protocol, arbitrary package-trigger
compensation, Unix-group rollback, login-shell rollback, or cross-authority
rollback is required. Existing Task 3 code implementing those mechanisms must
be removed or simplified with focused regression coverage.

Harbor usage observations remain measured state
`U_DOCKER_REGISTRY_MB`; they never become package input and never alter
`DOCKER_STORAGE_MB`. A quota decrease below fresh observed usage fails before
desired-state publication. Provider-unavailable reconciliation remains pending
and does not change workload state.

## Milestone 1: Disabled authority and entitlement - COMPLETE

### Task 1: Consolidate contract, provider authority, status, and endpoint guards

**Files:**
- Existing: `.docs/contracts/harbor-provider.md`
- Existing: `func/vx/harbor/{main.sh,common.sh,audit.sh}`
- Create: `func/vx/harbor/status.sh`
- Create: `bin/v-list-harbor-registry`
- Existing: `test/harbor/{lib.sh,run-focused.sh,test-state.sh,test-fixtures.sh}`
- Create: `test/harbor/test-status.sh`

- [x] **Step 1: Preserve completed contract and harness evidence**

Keep commits `776b8485`, `c86361cf`, `b0e8886b`, `56c78dc6`, and
`0229c27e`. The contract fixes command/state/lock/secret boundaries; fixtures
model only allowlisted Harbor routes, bounded bodies, redacted logs, Docker
Compose state, and systemd state.

- [x] **Step 2: Preserve completed disabled provider authority**

Keep commits `f693e830`, `c0f2b7d7`, `48ed9d97`, `81a99287`,
`accb81ba`, `ed8cec28`, and `d132b88b`. Provider preparation remains
root-only, exact-schema, atomic, locked, and non-mutating while disabled.
Origin validation supports shipped modern and legacy Vesta TLS configuration.

- [x] **Step 3: Add read-only status and endpoint guards**

`v-list-harbor-registry` emits a fixed redacted schema containing mode,
pinned/running version, derived origin, health summary, pending-operation
counts, backup age, and certificate state. It never returns credentials,
internal URLs, raw Harbor responses, filesystem paths, or environment data.
Endpoint helpers accept only fixed root-owned Unix-socket API paths and exact
public `/v2/` or `/service/token` ingress.

- [x] **Step 4: Run task-owned tests and commit**

```bash
bash -n func/vx/harbor/*.sh bin/v-list-harbor-registry
bash test/harbor/test-state.sh
bash test/harbor/test-status.sh
git diff --check
git commit -m "feat(harbor): complete disabled provider authority"
```

### Task 2: Simplify package entitlement and forward reconciliation

**Files:**
- Existing: `func/vx/compose/package.sh`
- Existing: `func/vx/harbor/package.sh`
- Existing: `bin/v-{add-user,change-user-package,list-user,list-users,list-user-package}`
- Existing: `web/inc/vx_compose_package.php`
- Existing: `web/templates/admin/{add_package,edit_package,list_packages}.html`
- Existing: `install/debian/{7,8,9,10,11,12,13}/packages/*.pkg`
- Existing: `test/compose/test-package-integration.sh`
- Existing: `test/test_compose_package_form.php`
- Existing: `test/harbor/test-package-quota.sh`

- [x] **Step 1: Preserve completed entitlement evidence**

Keep `b35d423a` and its package fields, shipped defaults, output/form
coverage, measured-usage separation, and provider-before-owner lock order.
Keep later commits in history; do not rewrite them.

- [x] **Step 2: Replace rollback machinery with pending operations**

Remove superseded HMAC token, preimage, atomic exchange, cross-writer CAS,
trigger compensation, and cross-authority rollback code added by
`a4d72bd2`, `6a304088`, `179298d2`, and `cc2e816b`. Implement exact
`pending|converged|failed` operation state, idempotent operation IDs,
conflict blocking, bounded retry metadata, and
`vx_harbor_package_transition_recover OWNER` as forward reconciliation.

- [x] **Step 3: Prove desired-state behavior**

Tests must show disabled mode converges without network; managed mode rejects a
decrease below fresh usage; provider outage leaves desired Vesta state plus a
pending operation without changing workloads; retry uses the same operation
ID; success converges Harbor quota and shell access; unresolved state blocks a
second package change; measured usage remains independent.

- [x] **Step 4: Run task-owned tests and commit**

```bash
bash -n func/vx/compose/package.sh func/vx/harbor/package.sh bin/v-add-user \
  bin/v-change-user-package bin/v-list-user bin/v-list-users \
  bin/v-list-user-package test/harbor/test-package-quota.sh
php -d short_open_tag=1 -l web/inc/vx_compose_package.php
bash test/compose/test-package-integration.sh
php test/test_compose_package_form.php
bash test/harbor/test-package-quota.sh
git diff --check
git commit -m "refactor(harbor): reconcile package quota forward"
```

### Milestone 1 acceptance

- [x] Run `bash test/harbor/run-focused.sh` once.
- [x] Perform one independent specification/security review covering Tasks 1–2.
- [x] Fix only milestone blockers and recheck those numbered blockers.
- [x] Record commits, tests, review result, deferred findings, and Milestone 2
  as the next milestone.

#### Milestone 1 record

- Product behavior: Added redacted read-only status and fixed endpoint guards;
  retained exact disabled provider authority and package fields; replaced
  cross-authority rollback/CAS machinery with root-owned
  `pending|converged|failed` forward reconciliation. Operation publication is
  durable before desired-state rename, stale journal/live-state mismatches
  cannot mutate Harbor, and the narrow quota setter uses only the protected
  Unix socket.
- Commits: `4dc2c92c`, `de99afc2`. Earlier implementation evidence remains
  recorded under Preserved implementation evidence.
- Focused tests: touched Bash/PHP syntax, Harbor state/status/package quota,
  Compose package integration, PHP package form, and `git diff --check`
  passed. `test/harbor/run-focused.sh` ran exactly once for the milestone and
  passed all four suites.
- Review: Initial review found four blockers: mutating status, uncoupled
  journal publication, missing production quota setter, and numeric quota
  schema. `de99afc2` fixed all four; the same reviewer rechecked only those
  blockers and returned PASS.
- Deferred: General Harbor API coverage remains Task 5. Startup/owner-wide
  recovery integration remains Task 6.
- Next: Milestone 2, verified installation and shared TLS ingress.

## Milestone 2: Verified installation and shared TLS ingress

### Task 3: Pin and verify the Harbor release

**Files:**
- Create: `install/harbor/release-manifest.json`
- Create: `install/harbor/cosign-policy.json`
- Create: `func/vx/harbor/release.sh`
- Create: `test/harbor/test-release-verification.sh`

- [ ] **Step 1: Add failing release trust fixtures**

Cover exact version, archive digest, image digests, Cosign identity/issuer,
offline bundle, unsupported architecture, tag-only image, signature mismatch,
and tampered generated configuration.

- [ ] **Step 2: Implement verification**

Download only the manifest-declared HTTPS URL, verify archive SHA-256 and
Cosign bundle before extraction, reject links/unsafe paths, pin every runtime
image by digest, and store only non-secret verification evidence.

- [ ] **Step 3: Validate and commit**

```bash
bash -n func/vx/harbor/release.sh test/harbor/test-release-verification.sh
bash test/harbor/test-release-verification.sh
git diff --check
git commit -m "feat(harbor): verify pinned Harbor release"
```

### Task 4: Install transactionally with shared TLS ingress and rollback

**Files:**
- Create: `func/vx/harbor/{install.sh,ingress.sh}`
- Create: `bin/v-install-harbor-registry`
- Create: `install/harbor/vesta-harbor.service`
- Create: `install/harbor/harbor-registry.conf.tpl`
- Create: `test/harbor/{test-install.sh,test-ingress.sh,test-host-boundary.sh}`

- [ ] **Step 1: Model installation and ingress failures**

Focused fixtures cover prerequisite, disk, release, config generation,
Compose, migration, health, nginx validation/reload, socket ownership,
certificate, and interrupted-install failures. Every failure must restore the
prior provider/nginx/systemd state while retaining Harbor data by default.

- [ ] **Step 2: Implement root-owned installation**

Under the exclusive provider lock, stage verified configuration, secrets via
protected files/stdin, systemd unit, and Compose project `vesta-harbor`.
Bind Harbor only to `/run/vesta-harbor/proxy.sock`; reject host TCP
listeners, host-network mode, Docker socket mounts, unsafe paths, and
unverified images.

- [ ] **Step 3: Implement exact shared ingress**

Render only exact `/v2/` and `/service/token` proxy routes on the existing
Vesta TLS server. Portal, `/api/`, metrics, and Unix socket remain
root/admin-local. Validate nginx before atomic activation and reload; rollback
all generated authority if validation or health fails.

- [ ] **Step 4: Validate and commit**

```bash
bash -n func/vx/harbor/{install,ingress}.sh bin/v-install-harbor-registry
bash test/harbor/test-install.sh
bash test/harbor/test-ingress.sh
bash test/harbor/test-host-boundary.sh
git diff --check
git commit -m "feat(harbor): install registry behind Vesta TLS"
```

### Milestone 2 acceptance

- [ ] Run `bash test/harbor/run-focused.sh` once.
- [ ] Perform one specification/security review of release trust, installation,
  rollback, Unix-socket isolation, and ingress.
- [ ] Fix only milestone blockers and record the milestone result.

## Milestone 3: Owner registry lifecycle

### Task 5: Add the allowlisted Harbor API adapter

**Files:**
- Create: `func/vx/harbor/api.sh`
- Create: `test/harbor/test-api.sh`

- [ ] **Step 1: Test allowlist and secret transport**

Cover only pinned API methods/routes, fixed Unix socket, bounded stdin/output,
empty environment, curl config credentials, redaction, status validation,
timeouts, malformed JSON, and provider outage.

- [ ] **Step 2: Implement fixed adapters**

Expose typed helpers for health, project, quota, robot, artifact, repository,
and volume operations. No caller supplies a URL, socket, arbitrary path,
permission set, owner, or credentials.

- [ ] **Step 3: Validate and commit**

```bash
bash -n func/vx/harbor/api.sh test/harbor/test-api.sh
bash test/harbor/test-api.sh
git diff --check
git commit -m "feat(harbor): add protected API adapter"
```

### Task 6: Reconcile owners, quota, and runtime credentials

**Files:**
- Create: `func/vx/harbor/{owners.sh,quota.sh,credentials.sh}`
- Create: `bin/v-sync-harbor-registry-owner`
- Create: `bin/v-sync-harbor-registry-owners`
- Create: `bin/v-list-harbor-registry-owners`
- Modify: `func/vx/harbor/package.sh`
- Create: `test/harbor/{test-owner-reconcile.sh,test-credentials.sh}`

- [ ] **Step 1: Test deterministic owner isolation**

Derive owner from Vesta state, map one private Harbor project per eligible
owner, enforce byte quota from `DOCKER_REGISTRY_MB`, observe usage, create a
pull-only runtime robot, and reject cross-owner IDs/names/permissions.

- [ ] **Step 2: Implement idempotent reconciliation**

Use operation IDs and owner mappings to create/update project, quota, runtime
robot, protected pull credential, observation, and package-operation state.
Repeated calls converge; outage records pending/failed state without changing
workloads. Startup and owner reconciliation invoke pending-operation recovery.

- [ ] **Step 3: Protect runtime credentials**

Store runtime credentials only in existing protected Compose registry state,
never argv/environment/output. Rotation writes new credential, validates it,
switches authority, then revokes the old robot.

- [ ] **Step 4: Validate and commit**

```bash
bash -n func/vx/harbor/{owners,quota,credentials,package}.sh \
  bin/v-{sync-harbor-registry-owner,sync-harbor-registry-owners,list-harbor-registry-owners}
bash test/harbor/test-owner-reconcile.sh
bash test/harbor/test-credentials.sh
bash test/harbor/test-package-quota.sh
git diff --check
git commit -m "feat(harbor): reconcile owner registry authority"
```

### Task 7: Add publisher, discovery, and lifecycle revocation

**Files:**
- Create: `func/vx/harbor/publisher.sh`
- Modify: `bin/v-run-user-docker-command`
- Modify: `bin/v-docker`
- Modify: owner/package suspend, unsuspend, delete, and package lifecycle hooks
- Create: `test/harbor/{test-publisher.sh,test-discovery.sh,test-revocation.sh}`

- [ ] **Step 1: Test owner-derived tenant flows**

`registry-info` returns only the derived origin, repository namespace,
project, quota/usage, and readiness. Publisher change consumes a bounded secret
from stdin and returns no secret. Runtime and publisher robots are separate.

- [ ] **Step 2: Implement lifecycle and revocation**

Suspend/package-ineligible/delete transitions revoke publisher then runtime
credentials, block new pulls/pushes, and preserve artifacts by default.
Unsuspend/eligibility reconciles fresh credentials. Existing running
containers and routes are never mutated by provider outage or revocation.

- [ ] **Step 3: Validate and commit**

```bash
bash -n func/vx/harbor/publisher.sh bin/v-docker bin/v-run-user-docker-command
bash test/harbor/test-publisher.sh
bash test/harbor/test-discovery.sh
bash test/harbor/test-revocation.sh
git diff --check
git commit -m "feat(harbor): add tenant registry lifecycle"
```

### Milestone 3 acceptance

- [ ] Run `bash test/harbor/run-focused.sh` once.
- [ ] Perform one specification/security review of API isolation, ownership,
  quota, credentials, publisher/discovery, revocation, and outage behavior.
- [ ] Fix only milestone blockers and record the milestone result.

## Milestone 4: Operations and operator surfaces

### Task 8: Add health, encrypted backup validation, disable, and bounded operations

**Files:**
- Create: `func/vx/harbor/{health.sh,backup.sh,disable.sh}`
- Create: `bin/v-backup-harbor-registry`
- Create: `bin/v-restore-harbor-registry`
- Create: `bin/v-plan-disable-harbor-registry`
- Create: `bin/v-disable-harbor-registry`
- Create: `test/harbor/{test-health.sh,test-backup.sh,test-disable.sh}`

- [ ] **Step 1: Implement bounded health and observations**

Observe provider health, certificate state, volume usage, owner usage/quota,
pending operations, and credential readiness. Observations are bounded,
redacted, timestamped, and do not become authority.

- [ ] **Step 2: Implement encrypted backup and validate-only restore**

Quiesce consistently under the exclusive provider lock, create a manifest,
encrypt before leaving protected staging, exclude curl credentials, robot
secrets, and plaintext keys, and verify ciphertext plus manifest. Restore
`validate` decrypts only in protected temporary storage, validates schema,
digests, version, ownership, and capacity, then removes plaintext. Apply is
deferred for first release and documented as an operator recovery procedure.

- [ ] **Step 3: Implement disable planning and execution**

Plan emits blockers, retained data, affected owners, and a short-lived
confirmation token. Disable revokes credentials, removes public ingress, stops
the provider, and marks mode disabled without deleting data or mutating tenant
workloads/routes/firewall.

- [ ] **Step 4: Validate and commit**

```bash
bash -n func/vx/harbor/{health,backup,disable}.sh \
  bin/v-{backup-harbor-registry,restore-harbor-registry,plan-disable-harbor-registry,disable-harbor-registry}
bash test/harbor/test-health.sh
bash test/harbor/test-backup.sh
bash test/harbor/test-disable.sh
git diff --check
git commit -m "feat(harbor): add bounded registry operations"
```

### Task 9: Add essential panel surfaces and deployment documentation

**Files:**
- Modify: existing admin service/package and tenant Docker project pages
- Modify: `web/inc/vx_compose_package.php`
- Modify: `docs/container-orchestration.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`
- Modify: `.docs/contracts/{harbor-provider,compose-images,compose-shell-access}.md`
- Create: `test/test_harbor_panel.php`
- Create: `test/harbor/test-doc-contract.sh`

- [ ] **Step 1: Add minimal panel status**

Admin sees mode, health, certificate, storage, backup age, and pending/failed
operation counts. Tenant sees registry origin, namespace, quota/usage, runtime
readiness, and publisher rotate/disable actions. Never render secrets, raw API
responses, internal paths, or Harbor administration.

- [ ] **Step 2: Document the complete tenant pipeline**

Document package entitlement, SSH identity, local build, publisher credential,
digest push, `registry-info`, immutable preview/pull/apply, health acceptance,
revocation, outage behavior, and why no SCP/rsync/archive/raw Docker path is
needed. Keep private-repository caveats in their owning repositories.

- [ ] **Step 3: Validate and commit**

```bash
php -d short_open_tag=1 test/test_harbor_panel.php
bash test/harbor/test-doc-contract.sh
git diff --check
git commit -m "docs(harbor): add operator and tenant registry guidance"
```

### Milestone 4 acceptance

- [ ] Run `bash test/harbor/run-focused.sh` once.
- [ ] Perform one specification/security review of operational state,
  encrypted backup validation, disable behavior, panel secret boundaries, and
  documentation.
- [ ] Fix only milestone blockers and record the milestone result.

## Milestone 5: Development acceptance and release closure

### Task 10: Perform development-host acceptance

**Files:**
- Create: `.docs/validation/2026-08-08-vesta-managed-harbor-development.md`
- Modify: focused fixtures only when acceptance exposes a product defect

- [ ] **Step 1: Pass local milestone acceptance**

```bash
bash test/harbor/run-focused.sh
```

Expected: one clean focused run; no broad ShellCheck or full readiness.

- [ ] **Step 2: Stage and validate development**

Stage through `gizmo@192.168.100.16` to
`debian@192.168.100.100`. Verify pinned release, no host Harbor TCP listener,
Unix-socket permissions, exact Vesta TLS routes, no portal/API exposure,
eligible owner reconciliation, quota, separate credentials, immutable
push/pull/deploy, revocation, outage isolation, encrypted backup validation,
disable plan, and rollback retention.

- [ ] **Step 3: Record exact evidence**

Record commit, host, commands, redacted outputs, image digests, operation IDs,
listener/socket evidence, owner/quota evidence, workload revision/health/drift,
backup validation, rollback location, and explicit production deferral.

- [ ] **Step 4: Commit acceptance**

```bash
git add .docs/validation test/harbor
git commit -m "docs(harbor): record development acceptance"
```

### Task 11: Final release review and closeout

**Files:**
- Modify: this plan
- Modify: contracts/docs/evidence only for closeout corrections

- [ ] **Step 1: Run the release gate exactly once**

```bash
bash test/compose/run-production-readiness-limited.sh
```

Do not invoke broad standalone ShellCheck, the canonical gate directly, or
`VX_READINESS_ALLOW_UNLIMITED=yes`.

- [ ] **Step 2: Run final independent reviews**

Perform one final specification review across the implementation and one final
code-quality/security review. Fix only release blockers; rerun only affected
focused tests and the limited launcher if a release-gate input changed.

- [ ] **Step 3: Close the plan**

Record milestone commits, focused tests, development evidence, limited-gate
result, final reviews, deferred hardening, rollback/retention, and
`production deployment: deferred`. Commit the closeout without deploying.

## Requirement traceability

| Requirement | Owning task | Acceptance evidence |
| --- | --- | --- |
| Pinned digest/signature verification | 3 | `test-release-verification.sh` |
| Root authority, status, endpoint guards | 1 | `test-state.sh`, `test-status.sh` |
| Package quota and forward recovery | 2, 6 | package integration and quota tests |
| No raw Docker/Harbor administration | 4, 7 | host-boundary, discovery tests |
| No Harbor host TCP listener | 4, 10 | ingress/host-boundary and host evidence |
| Existing Vesta TLS endpoint only | 1, 4 | status/ingress tests |
| Secret exclusion | 1, 5–9 | fixture log assertions and panel tests |
| Owner isolation and quota | 6 | owner reconciliation tests |
| Separate runtime/publisher credentials | 6, 7 | credentials/publisher tests |
| Revocation and outage isolation | 7 | revocation tests and development evidence |
| Transactional install/ingress | 4 | install/ingress rollback tests |
| Encrypted backup validation | 8 | backup tests and development evidence |
| Health/usage/quota/certificate state | 1, 8, 9 | status, health, panel tests |
| Tenant deployment workflow | 7, 9, 10 | discovery/docs/development evidence |
| Development acceptance | 10 | validation record |
| Production deferred | 10, 11 | validation and closeout records |

## Test ownership and cadence

| Suite | Owner | Cadence |
| --- | --- | --- |
| Individual `test/harbor/test-*.sh` and PHP tests | Corresponding task | While implementing that task |
| `test/harbor/run-focused.sh` | Milestone acceptance | Once per milestone |
| `test/compose/test-package-integration.sh` | Task 2 | During package changes |
| `test/compose/run-production-readiness-limited.sh` | Task 11 | Once at release closure |
| Broad standalone ShellCheck/full/unlimited gate | None | Prohibited |

## Preserved implementation evidence

- Plan/spec baseline: `024e2014`, `3142c72b`.
- Harness and contract: `776b8485`, `c86361cf`, `b0e8886b`,
  `56c78dc6`, `0229c27e`, closeout `34335823`.
- Provider authority: `f693e830`, `c0f2b7d7`, `48ed9d97`,
  `81a99287`, `accb81ba`, `ed8cec28`, `d132b88b`, closeout
  `8a4475c2`.
- Package entitlement and superseded rollback experiments: `b35d423a`,
  `a4d72bd2`, `6a304088`, `179298d2`, `cc2e816b`. History is retained;
  Task 2 adapts the working tree to the approved forward-convergence model.

## Deferred operational hardening

These are not first-release blockers:

- Rich Harbor panel UI beyond status, quota, readiness, and publisher actions.
- Automated Harbor upgrade; first release remains pinned and upgrades use a
  documented manual replacement procedure.
- Automated restore apply; encrypted backup plus validate-only restore and a
  documented operator recovery procedure are sufficient.
- Metrics beyond health, usage, quota, pending operations, backup age, and
  certificate state.
- Optional scanner/Trivy operation.
- Exhaustive documentation assertion tests.
- Automatic production deployment. Production remains explicitly deferred.

## Execution handoff

Execute with `$milestone-driven-implementation`. Begin by finishing Milestone
1 Tasks 1–2, including simplifying the already-added Task 3 rollback machinery.
Do not start Milestone 2 until one Milestone 1 specification/security review
passes and its closeout record is committed.
