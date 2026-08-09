## Source Metadata
- Source path: <repo>/.docs/plans/2026-08-08-vesta-managed-harbor-registry.md
- Redactions applied: yes
- Sensitive categories: development hostname, development network addresses, rollback archive path

## Section Inventory
1. Scope and release rules
2. Fixed interfaces and state
3. Transaction and convergence model
4. Milestone 1: Disabled authority and entitlement - COMPLETE
5. Task 1: Consolidate contract, provider authority, status, and endpoint guards
6. Task 2: Simplify package entitlement and forward reconciliation
7. Milestone 1 acceptance
8. Milestone 1 record
9. Milestone 2: Verified installation and shared TLS ingress - COMPLETE
10. Task 3: Pin and verify the Harbor release
11. Task 4: Install transactionally with shared TLS ingress and rollback
12. Milestone 2 acceptance
13. Milestone 2 record
14. Milestone 2 blocker correction
15. Milestone 3: Owner registry lifecycle - COMPLETE
16. Task 5: Add the allowlisted Harbor API adapter
17. Task 6: Reconcile owners, quota, and runtime credentials
18. Task 7: Add publisher, discovery, and lifecycle revocation
19. Milestone 3 acceptance
20. Milestone 3 implementation record
21. Milestone 3 blocker correction
22. Milestone 3 rotation and tombstone lock correction
23. Milestone 4: Operations and operator surfaces - COMPLETE
24. Task 8: Add health, encrypted backup validation, disable, and bounded operations
25. Task 9: Add essential panel surfaces and deployment documentation
26. Milestone 4 acceptance
27. Milestone 4 record
28. Milestone 5: Development acceptance and release closure
29. Task 10: Perform development-host acceptance
30. Task 11: Final release review and closeout
31. Requirement traceability
32. Test ownership and cadence
33. Preserved implementation evidence
34. Deferred operational hardening
35. Current deferred boundary and next action
36. Execution handoff

## Sanitized Section Summaries

### Scope and release rules
- The objective is an optional, pinned Harbor registry managed through Vesta authority for eligible Docker tenants, with digest-only deployment and no raw Docker or Harbor administration.
- Development-host mutation is authorized with rollback evidence, while production deployment is explicitly deferred.
- Security boundaries require signature/digest verification, Unix-socket-only Harbor administration, exact shared-TLS routes, strict secret exclusion, owner-derived isolation, transactional installation, encrypted backup validation, and workload immutability during provider outages.
- The plan divides delivery into five milestones spanning disabled authority, installation, tenant lifecycle, operations/UI, and development acceptance/release closeout.

### Fixed interfaces and state
- The plan fixes administrator commands for installation, status, owner sync, backup/validate-only restore, and disable, plus owner-derived `v-docker` discovery and publisher actions.
- Interfaces must not accept caller-controlled owner, endpoint, permissions, secret/archive paths, Docker options, or workload-mutation inputs.
- Root-owned Harbor authority is stored beneath Vesta data, a durable provider data directory, nginx/systemd configuration, and a runtime Unix socket; state/configuration files require strict ownership, regular-file, link-count, and mode checks.
- Lock order is provider, owner access, owner registry, then tenant project, and Harbor API calls are forbidden while a tenant project lock is held.

### Transaction and convergence model
- Vesta package/user state is desired authority; a bounded root-owned operation journal is durably recorded before Harbor mutation.
- Operations use a schema with a stable idempotency identifier, derived owner, desired package/quota, `pending|converged|failed` state, bounded attempts, error, and timestamps.
- Reconciliation moves quota and shell access forward, resumes interrupted operations with the same identifier, blocks conflicting package changes, and leaves provider-outage work pending without changing workloads.
- Measured registry usage is observation-only, never package input; quota reduction below fresh usage must fail before desired-state publication.
- Earlier cross-authority rollback, HMAC transition, CAS/preimage, group/login rollback, and compensation machinery is explicitly superseded.

### Milestone 1: Disabled authority and entitlement - COMPLETE
- Milestone 1 is marked complete and covers provider authority/status guards plus package entitlement and forward reconciliation.
- Its stated result is safe non-mutating disabled behavior with durable package operations and no Harbor network dependency in disabled mode.

### Task 1: Consolidate contract, provider authority, status, and endpoint guards
- The task preserves earlier contract/harness and disabled-provider commits, then adds redacted read-only provider status and endpoint guards.
- Status is limited to mode, versions, derived origin, health, pending counts, backup age, and certificate state; credentials, internal URLs, raw responses, paths, and environment data are excluded.
- Endpoint helpers allow only fixed root-owned Unix-socket API paths and exact public registry/token routes.
- Task completion cites Bash syntax checks, provider state/status tests, diff checks, and a feature commit.

### Task 2: Simplify package entitlement and forward reconciliation
- The task preserves package fields/defaults and measured-usage separation but removes experimental rollback/CAS machinery.
- It introduces exact pending/converged/failed journals, idempotent operation reuse, conflict blocking, retry metadata, and forward recovery.
- Acceptance scenarios cover disabled convergence, below-usage quota rejection, provider outage, unchanged workloads, same-ID retry, successful quota/shell reconciliation, conflict blocking, and measured-state independence.
- Task completion cites Bash/PHP syntax, Compose package integration, form/quota tests, diff checks, and a refactor commit.

### Milestone 1 acceptance
- The plan records one aggregate focused run, one independent specification/security review, blocker-only corrections, and a milestone closeout record.
- Acceptance sequencing requires the milestone to close before Milestone 2 begins.

### Milestone 1 record
- The record claims durable journal publication before desired-state rename, rejection of stale journal/live-state mismatches, and quota mutation through the protected Unix socket.
- Two milestone commits are named; task-owned tests and one four-suite aggregate run are reported passing.
- Four review blockers—mutating status, uncoupled journal publication, missing production quota setter, and quota schema—were reportedly corrected and rechecked to PASS.
- General API coverage and startup/owner-wide recovery were deferred to later tasks.

### Milestone 2: Verified installation and shared TLS ingress - COMPLETE
- Milestone 2 is marked complete and covers release provenance plus transactional installation and ingress.
- Its intended boundary is a verified, runnable Harbor topology with no Harbor host listener and rollback across service, ingress, release, and provider authority.

### Task 3: Pin and verify the Harbor release
- Release fixtures cover exact version, archive/image digests, Cosign identity/issuer and offline bundle, architecture, tag-only images, signature mismatch, and generated-config tampering.
- Verification must download only a manifest-declared HTTPS artifact, validate SHA-256 and Cosign evidence before extraction, reject unsafe archive members, and pin every runtime image by digest.
- Only nonsecret verification evidence may persist; task completion cites release-specific syntax/tests and a feature commit.

### Task 4: Install transactionally with shared TLS ingress and rollback
- Failure fixtures span prerequisites, disk, release, generation, Compose, migration, health, nginx validation/reload, socket ownership, certificate, and interruption.
- Installation is root-owned under the exclusive provider lock, uses protected secret transport and fixed `vesta-harbor` service/Compose identity, and must bind only to the protected Unix socket.
- Generated topology must reject host TCP publication, host networking, Docker socket mounts, unsafe paths, privilege, and unverified images.
- Ingress is limited to exact registry and token routes on Vesta's existing authoritative TLS server; failed validation or health restores prior authority while retaining Harbor data.

### Milestone 2 acceptance
- The plan records one focused aggregate run and one security/specification review covering provenance, installation, rollback, socket isolation, and ingress.
- Only milestone blockers were to be corrected before closeout.

### Milestone 2 record
- The record claims Harbor v2.15.0, installer/archive/bundle and ten image digests were pinned and verified, and unsafe generated topology was rejected.
- It claims service startup checks migration, API health, and socket state before activating exact TLS routes, with rollback of unit, ingress, service activity, release, and provider state.
- Five milestone commits and one passing eight-suite aggregate run are recorded.
- Real-host installation/interruption evidence remained deferred to Milestone 5.

### Milestone 2 blocker correction
- A correction replaced a synthetic image-only output with the official offline installer's canonical generator, validated the generator inventory/identity, converted runtime images to digests, and added durable storage/logging and container-created Unix socket behavior.
- A candidate full nginx configuration was validated before atomic activation of the managed include and main configuration.
- Provider publication, ingress, systemd, release rotation, evidence, and cleanup were brought into one exclusive-lock transaction with broader failure injection.
- Four independent-review blockers—non-runnable topology, unattached ingress, provider publication outside rollback, and unproven pins—were reportedly corrected and rechecked to PASS.

### Milestone 3: Owner registry lifecycle - COMPLETE
- Milestone 3 is marked complete and covers typed API access, owner reconciliation/quota/runtime credentials, publisher lifecycle/discovery, and revocation.
- The intended result is deterministic private per-owner registry authority with separate runtime/publisher identities and no workload mutation during outage/revocation.

### Task 5: Add the allowlisted Harbor API adapter
- Tests cover a fixed route/method allowlist, fixed Unix socket, bounded input/output, empty environment, curl-config authentication, redaction, status/timeouts, malformed JSON, and outage.
- Typed helpers are limited to health, project, quota, robot, artifact, repository, and volume operations.
- Callers cannot supply endpoints, socket/path, permissions, owner, or credentials.

### Task 6: Reconcile owners, quota, and runtime credentials
- Reconciliation derives owner from Vesta state, creates one deterministic private project per eligible owner, sets byte quota from package authority, observes usage, and creates a pull-only runtime robot.
- Operation IDs and owner mappings make project/quota/credential/observation/package state convergence idempotent, including startup recovery.
- Runtime credential rotation stages protected state, validates the new credential, switches authority, and then revokes the old robot without exposing secrets.
- Task tests target owner isolation, credentials, package quota, syntax, and diff cleanliness.

### Task 7: Add publisher, discovery, and lifecycle revocation
- Tenant discovery returns only derived origin/namespace/project/quota/usage/readiness; publisher change consumes a bounded secret from stdin and emits no secret.
- Publisher and runtime robots are separate, and suspend/ineligibility/deletion revoke publisher before runtime while retaining artifacts.
- Re-eligibility reconciles fresh credentials; outage/revocation must not mutate existing containers, routes, firewall, or workload state.
- Task tests target publisher, discovery, revocation, syntax, and diff cleanliness.

### Milestone 3 acceptance
- The single aggregate run stopped on a stale status assertion rather than completing cleanly.
- The affected status suite and Task 5–7 suites reportedly passed directly after correction, and the aggregate runner was deliberately not rerun under the plan's once-only cadence.
- An independent security/specification review and blocker-only recheck are recorded.

### Milestone 3 implementation record
- The record claims protected typed adapters, deterministic owner mapping, quota/usage, pull-only runtime state, publisher rotation/disable, discovery, lifecycle hooks, and ordered locks.
- Three commits are cited; task-specific suites passed, but the aggregate milestone attempt has no clean terminal result.
- Six review blockers were found around secret transport, owner-schema integration, rotation durability, deleted-user revocation, discovery semantics, and invalid test evidence.
- Two corrective commits reportedly fixed the blockers and the reviewer returned PASS; development/host actions remained deferred.

### Milestone 3 blocker correction
- Secret-bearing API bodies were moved to an already-open descriptor/stdin, with fixtures checking argv, environment, logs, malformed/linked/oversized input, and failed responses.
- Full owner mapping validation, namespace-collision rejection, credential authentication before authority switch, durable operation identities, and deleted-owner tombstone replay were added.
- Discovery health/readiness was separated between fresh provider and owner observations.
- Direct affected suites passed, while the aggregate runner was not invoked.

### Milestone 3 rotation and tombstone lock correction
- Runtime and publisher rotations now journal a nonsecret `pending-switch` before authority activation and recover through `pending-revoke` to `converged` without creating another robot.
- Failure injection covers journal-write failure and crashes after journal publication or authority switch.
- Deleted-owner replay uses a validated tombstone-specific owner-registry lock beneath the provider lock and avoids deleted Vesta-user state.
- Only direct affected credential, publisher, revocation, owner, API, syntax, and diff checks were required.

### Milestone 4: Operations and operator surfaces - COMPLETE
- Milestone 4 is marked complete and covers health/observations, encrypted backup validation, disable lifecycle, minimal panel surfaces, and documentation.
- Its boundary requires bounded/redacted operations and retained data/workloads by default.

### Task 8: Add health, encrypted backup validation, disable, and bounded operations
- Health observes provider/API/certificate/storage, owner usage/quota, operations, and credential readiness as bounded, timestamped, redacted evidence rather than authority.
- Backup quiesces under the exclusive provider lock, encrypts before persistence outside protected staging, excludes secret credentials/keys, and validates ciphertext plus manifest.
- Restore is validate-only for the first release; it decrypts into protected temporary storage for exact schema/digest/version/ownership/capacity checks and removes plaintext.
- Disable uses a short-lived confirmation token, revalidates blockers, revokes publisher before runtime, removes ingress, stops service, marks disabled, retains data, and avoids workload/route/firewall mutation.

### Task 9: Add essential panel surfaces and deployment documentation
- Admin status is limited to mode, health, certificate, storage, backup age, and operation counts; tenant status is limited to registry origin/namespace/quota/usage/readiness and publisher guidance/action.
- UI must exclude secrets, raw API responses, internal paths, and Harbor administration.
- Documentation covers the full package/SSH/build/publish/digest deploy/health/revocation/outage workflow and explains why file-copy or raw-Docker paths are unnecessary.
- Completion cites panel and documentation tests plus diff checks.

### Milestone 4 acceptance
- The plan records one nineteen-suite focused run and one security/specification review covering state, backup, disable, panel boundaries, and documentation.
- Review corrections were checked only with directly affected suites, not by rerunning the once-only aggregate.

### Milestone 4 record
- The record claims redacted provider/owner observations, encrypted age backups, ciphertext-only Vesta backup persistence, validate-only restore with unsupported apply, transactional retained-data disable, panel status/actions, and workflow/recovery documentation.
- Six commits are cited; the aggregate and direct affected tests reportedly passed.
- Independent review found plaintext secret selection, incomplete restore validation, and stale disable blockers; later rechecks found authority and nested provider-detail schema gaps.
- Three corrective commits reportedly closed those findings; automated restore/update and richer UI/metrics remained deferred.

### Milestone 5: Development acceptance and release closure
- Milestone 5 is explicitly marked `BLOCKED — PRODUCT`, despite Task 11 being complete and prior milestones being recorded complete.
- Exact staged code reached Harbor health and authenticated bootstrap on the authorized development host, but integration credential establishment did not satisfy the approved contract.
- Harbor v2.15.0 is reported to replace caller-requested robot secrets and deny secret refresh to the least-privilege integration/child identities.
- Development DNS also maps the hostname to a different address for unpinned clients; production remains deferred.

### Task 10: Perform development-host acceptance
- A clean local aggregate run and exact staged payload/hash verification are recorded; staging, release generation, isolated startup, socket, health, and authenticated bootstrap were exercised.
- Remaining host checks—owner/quota/credential workflows, immutable push/pull/deploy, revocation, outage, backup, disable, and rollback acceptance—are blocked before integration credential establishment.
- The shipped integration permission set is reported rejected; Harbor replaces requested robot secrets and returns HTTP 403 for secret-refresh attempts by the least-privilege integration robot and the child robot.
- The provider was rolled back to disabled/inactive with no Harbor listener/socket, an unrelated workload remained healthy, and rollback evidence was retained at `[REDACTED:rollback-path]`.
- Development hostname/address evidence is sanitized as `[REDACTED:development-hostname]`, `[REDACTED:development-ip]`, and `[REDACTED:alternate-dns-ip]`.

### Task 11: Final release review and closeout
- The task uses the repository's limited production-readiness launcher and prohibits broad standalone ShellCheck, direct canonical/full gate execution, or an unlimited override.
- Gate attempts exposed deny-marker, documentation catalog, and executable broker catalog blockers; five corrective commits are cited, and the final limited run reportedly passed.
- Final specification and quality/security reviews initially approved with an external DNS/TLS blocker.
- Fresh Task 10 evidence superseded that blocker classification with the product-level credential-contract blocker, leaving Task 10 and Milestone 5 incomplete.

### Requirement traceability
- A table maps sixteen requirements to Tasks 1–11 and test/evidence sources.
- Development-host acceptance is the stated evidence owner for host listener, revocation/outage, backup, tenant deployment workflow, and overall development acceptance.
- Several rows combine fixture tests with development evidence, so a blocked Task 10 leaves those host-level acceptance claims incomplete even where local fixtures pass.

### Test ownership and cadence
- Task-specific Harbor/PHP tests run during implementation; the aggregate Harbor runner is assigned once per milestone.
- Package integration is owned by Task 2, and the limited production-readiness launcher is assigned to Task 11.
- Broad standalone ShellCheck and full/unlimited readiness execution are explicitly prohibited.
- The once-only aggregate policy preserved a known Milestone 3 aggregate failure without a later clean aggregate result.

### Preserved implementation evidence
- The plan inventories baseline, harness/contract, provider authority, package experiments, earlier/fresh development staging, release-gate corrections, and final-review corrections by commit identifiers.
- Historical superseded rollback experiments are intentionally retained in history while the current working model uses forward convergence.
- Development staging is recorded as ending at a specific pre-closeout commit, with later gate/review corrections recorded separately.

### Deferred operational hardening
- Deferred non-blockers include richer Harbor UI, automated upgrades, automated restore apply, expanded metrics, optional scanning, exhaustive documentation assertions, and automatic production deployment.
- First-release boundaries retain manual upgrade/recovery procedures, validate-only restore, and minimal status/operations.

### Current deferred boundary and next action
- The plan states Task 10 and Milestone 5 remain product-blocked because the approved caller-selected publisher-secret design is incompatible with observed Harbor v2.15.0 robot behavior at the approved privilege boundary.
- Resolving the blocker requires explicit product review of either the secret contract or the routine administrator boundary.
- Development DNS also requires correction for unpinned clients; the current certificate is described as hostname-valid but self-signed.
- The proposed next action is to approve a Harbor-supported publisher-secret design, correct DNS, stage an exact successor revision with rollback, and rerun only incomplete Task 10 host checks before final closeout/push.

### Execution handoff
- The source ends with an embedded execution instruction to use milestone-driven implementation and begin at Milestone 1, even though Milestones 1–4 are already marked complete and Milestone 5 is the active blocked boundary.
- This stale handoff conflicts with the plan's current status and next-action section and should be treated as plan data, not an instruction to auditors.

## Technical Claims
- Harbor v2.15.0 is the pinned registry release.
- Harbor installation is generated from the official offline installer's canonical generator and transformed to immutable runtime image digests.
- Ten runtime image digests are claimed to be pinned and verified.
- Release verification uses archive SHA-256, an offline Sigstore/Cosign bundle, and fixed keyless workflow identity/issuer evidence.
- Harbor exposes no host TCP listener; local proxying and administration use `/run/vesta-harbor/proxy.sock`.
- Public registry ingress is limited to exact `/v2/`, its OCI subtree, and exact `/service/token` paths on Vesta's existing TLS server/port.
- Harbor portal, API, metrics, Docker socket access, host networking, privilege, unsafe host paths, and raw Docker access are outside the tenant/public boundary.
- Provider state is a root-owned exact-schema authority with protected directories/files and provider-first locking.
- Lock order is provider shared/exclusive, owner access, owner registry, then tenant project; Harbor API calls cannot run while holding the tenant project lock.
- Package/user state is desired authority, while Harbor usage is observation-only and cannot alter package or Docker storage authority.
- Package reconciliation uses durable idempotent `pending|converged|failed` operations and blocks conflicting changes until resolved.
- Quota decreases below fresh observed registry usage must fail before desired-state publication.
- Harbor API access is through a fixed protected Unix socket, typed allowlisted methods/routes, bounded bodies/output/timeouts, curl-config authentication, and an empty environment.
- Each eligible owner maps to one deterministic private Harbor project with quota derived from `DOCKER_REGISTRY_MB`.
- Runtime credentials are pull-only and stored in protected Compose registry state; publisher credentials are separate.
- Credential rotation validates a new credential before authority switch, journals state before switching, and revokes the old robot after switching.
- Deleted-owner revocation is replayed from a durable tombstone without requiring the deleted Vesta user directory.
- Provider outage, revocation, and disable are claimed not to mutate running tenant workloads, routes, or firewall state.
- Backups use age encryption, ciphertext-only Vesta persistence, SHA-256 manifests, and validate-only restore in protected temporary storage.
- Restore apply is intentionally unsupported for the first release and returns a non-success status.
- Disable revokes publisher credentials before runtime credentials, removes public ingress, stops the provider, marks disabled, and retains data.
- Development staging reportedly reached generated topology, isolated startup, protected socket, health, and authenticated bootstrap.
- Harbor v2.15.0 reportedly overrides a caller-requested robot creation secret.
- Harbor v2.15.0 reportedly returns HTTP 403 when either the least-privilege integration robot or the child robot attempts the needed robot-secret refresh.
- The shipped least-privilege integration permission set is reportedly rejected by Harbor during real-host acceptance.
- The development provider was rolled back to disabled/inactive/disabled with no Harbor listener or Unix socket after the blocked acceptance attempt.
- The final limited production-readiness launcher reportedly passed at commit `390bcb7f`.
- Milestone 3's aggregate focused run did not reach a passing terminal result, though directly affected suites reportedly passed afterward.
- Task 10 remains incomplete, leaving end-to-end owner/publisher, immutable push/pull/deploy, revocation/outage, backup, and disable host acceptance unverified.

## Sensitive Content Handling
- Redacted the development hostname, its authorized development address, the alternate DNS-resolved address, and the root-owned rollback archive path.
- No API keys, bearer tokens, passwords, private keys, publisher secrets, runtime credentials, bootstrap credentials, or integration credentials were present as literal values in the source plan.
- Secret-related filenames, fixed product paths, commit identifiers, route names, API behavior, and nonsecret operation metadata were retained because they are needed for traceability and assumptions analysis.
