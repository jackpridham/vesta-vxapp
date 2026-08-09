# Vesta-managed Harbor Registry Implementation Plan Audit

## Audit Scope

- Source plan: `.docs/plans/2026-08-08-vesta-managed-harbor-registry.md`.
- Sanitized snapshot: `.docs/plans/2026-08-08-vesta-managed-harbor-registry.audit-input.md`.
- Output report: `.docs/plans/2026-08-08-vesta-managed-harbor-registry.audit.md`.
- Scope: audit the implementation plan against the approved specification, structured technical evidence, previous implementation commits, local tests, and read-only development-host evidence without modifying any source artifact.
- Coverage: all 36 plan sections. Findings preserve the required order of Requirements Auditor, YAGNI Auditor, Assumptions Auditor, then explicitly requested Commit/Runtime Evidence.
- Evidence boundary: sanitized snapshot summaries locate plan claims; structured auditor outputs supply findings; the twelve numbered supplemental findings are included verbatim in substance with sensitive host/path values redacted.

### Baseline caveats

- The approved specification has already resolved the original publisher-secret product decision: Harbor v2.15.0 generates child secrets; Vesta accepts an age recipient and returns encrypted ciphertext. The plan’s caller-selected `registry-publisher-change` contract and “Harbor cannot satisfy the approved contract” blocker are stale.
- The development record preserves the historical caller-secret failure as evidence but explicitly supersedes its product-decision status with the source-validated generated-credential design.
- A corrected generated-credential implementation passed one clean local Harbor aggregate at `f41990e9`; later live defects were corrected with directly affected tests.
- Live acceptance exposed at least three concrete implementation defects after the design correction: invalid `page_size=1000`, an incorrect `root:root` socket expectation, and testing/reloading Debian nginx while editing Vesta panel nginx configuration.
- A protected marker-only transaction subsequently reached healthy Harbor, created and validated the integration identity, completed the delegated project/robot probe, and exited integration successfully.
- The final uninstrumented successor at `e3b2b19d` again reached health but failed to complete integration; rollback succeeded. The validation record does not provide a final error or precise failing integration step for that attempt.
- Harbor remains disabled because transactional activation did not complete and rollback deliberately restored the fail-closed disabled/inactive state. This is current live acceptance status, not proof that the approved Harbor-generated credential design is unsupported.
- Managed activation, tenant publisher delivery, owner quota, immutable push/pull/deploy, revocation/outage, backup validation, provider health, and administrative disable remain explicitly unclaimed on the development host.
- The development DNS discrepancy remains unresolved: the deployment client resolves the development hostname to a different address, although pinned SNI/hostname TLS to the authorized address succeeds.
- The latest limited readiness launcher attempt is not a pass: it was terminated with exit `143` after approximately 20 minutes, heavy disk reads, and swap exhaustion. Earlier plan text claiming a final limited-gate pass refers to an older revision and does not validate the generated-credential successor.
- The source specification still describes Harbor’s internal endpoint as “fixed loopback-only,” while the plan and validation use a protected Unix socket. Downstream technical review should resolve whether this is an intentional compatible refinement or a specification mismatch.
- The source specification requires complete applied-restore and controlled-upgrade behavior, while the plan labels automated restore apply and automated upgrade as deferred first-release hardening. This is an explicit plan/spec scope conflict unless separately approved.
- The specification’s removal planning requires dependency evidence including accepted workload references and dependent hosts; the plan’s recorded disable behavior may be narrower and needs implementation evidence.
- Previous commit contents were not included as standalone source-context files for this extraction. Commit-level claims require direct git inspection by the technical evidence pass.
- The plan’s final execution handoff tells workers to restart at Milestone 1 despite Milestones 1–4 being marked complete and Milestone 5 being the active boundary; this is internally stale and likely contributes to repeated or misdirected agent work.

## Source Requirements

1. [EXPLICIT] Audit the Vesta-managed Harbor implementation plan against the approved specification.
2. [EXPLICIT] Audit the plan against previous implementation commits and distinguish implemented behavior from plan claims.
3. [EXPLICIT] Audit the plan against the development validation record, including its historical failures, corrections, latest staging attempt, and final host state.
4. [EXPLICIT] Identify the actual reason Harbor remains disabled after roughly 24 hours of work.
5. [EXPLICIT] Explain why delivery took so long and why agents continue describing Harbor as nonfunctional.
6. [CONSTRAINT] Produce an evidence-based standalone audit without overwriting the source plan, approved specification, or development validation record.
7. [CONSTRAINT] Preserve the approved security, isolation, rollback, secret-handling, production-authorization, and constrained-host validation boundaries while evaluating or recommending corrections.
8. [EXPLICIT] Harbor must remain a root-owned Vesta platform service with distinct service, Compose, state, network, and lifecycle authority; tenant Compose commands must not control it.
9. [EXPLICIT] Harbor lifecycle operations must not stop, recreate, reroute, or otherwise mutate application workloads.
10. [EXPLICIT] Provider mode must be exactly `disabled` or `managed`; external-registry behavior must remain unchanged while disabled, and production mutation requires separate explicit authorization.
11. [CONSTRAINT] The first release is pinned to Harbor v2.15.0 and must verify the exact installer, checksum, signature identity, supported architecture, generated topology, and component image digests before activation.
12. [CONSTRAINT] Installation must fail before service replacement for unsafe ownership, invalid hostname/certificate/listener, route collision, insufficient prerequisites, unverified artifacts, or unsupported topology.
13. [EXPLICIT] The public registry origin must derive from Vesta’s authoritative hostname and current panel TLS port without accepting a caller-supplied hostname, port, URL, version, or installer.
14. [CONSTRAINT] Vesta’s existing panel nginx listener and certificate lifecycle remain authoritative; install and lifecycle operations must not create DNS, firewall, NAT, public-port, or independent-certificate state.
15. [CONSTRAINT] Public ingress is limited to the exact OCI `/v2/` namespace and exact token-service route; Harbor portal, administrative API, metrics, and non-allowlisted routes remain host-local.
16. [CONSTRAINT] Registry proxying must preserve OCI authentication/upload headers while preventing route normalization/fallthrough, panel credential leakage, Harbor cookies, sensitive logging, and authorization exposure outside exact registry/token routes.
17. [EXPLICIT] Managed mode must fail closed on unplanned Vesta hostname or panel-port changes.
18. [EXPLICIT] Shared Harbor API integration must use fixed root-owned local transport, exact executable paths, an empty environment, allowlisted method/path pairs, bounded schema-validated bodies, bounded timeouts, and redacted failures.
19. [CONSTRAINT] Bootstrap administrator and integration credentials must be distinct; bootstrap authority is recovery-only and must never be used as routine API fallback.
20. [EXPLICIT] The routine integration identity must be the approved least-privilege system robot with system scope `/`, wildcard project scope `*`, exact approved project/quota/volume/repository/robot create-read-list-delete actions, and no robot update/refresh authority.
21. [EXPLICIT] Routine lifecycle must use child create, verify, metadata switch, validated delete, and no robot update, refresh, disable, or bootstrap-administrator fallback.
22. [EXPLICIT] Harbor-generated one-time robot secrets are the approved v2.15.0 contract; Vesta must not attempt caller-selected creation secrets or later secret refresh.
23. [EXPLICIT] Each eligible owner must map deterministically and collision-safely to one persisted private Harbor project, using a readable safe name or full lowercase SHA-256 fallback.
24. [CONSTRAINT] Project creation must use only Harbor-supported private metadata, exactly `{"public":"false"}`, and must not invent unsupported metadata keys.
25. [EXPLICIT] Package authority must add `DOCKER_REGISTRY_MB` and observation-only `U_DOCKER_REGISTRY_MB`, with shipped defaults of zero and eligibility tied to ordinary `v-docker` checks plus positive/unlimited project and registry entitlement.
26. [EXPLICIT] Harbor usage is authoritative for registry bytes; registry quota must remain separate from `DOCKER_STORAGE_MB`, and quota changes must fail closed on stale/unavailable usage or reductions below current usage.
27. [EXPLICIT] Publisher rotation must be `v-docker registry-publisher-rotate < age-recipient`, accepting exactly one bounded validated native X25519 age recipient on stdin—not a publisher secret.
28. [CONSTRAINT] Harbor must generate the publisher secret once; Vesta must verify it and stream only one complete ASCII-armored age ciphertext to stdout, with no plaintext durability in files, state, journals, backups, logs, audit, argv, environment, JSON, or HTML.
29. [EXPLICIT] Publisher robots must be project-scoped pull-plus-push only, separate from runtime robots, and rotated by marked create, verify, atomic metadata switch, and validated deletion of the prior child.
30. [EXPLICIT] A lost one-time create response must leave a discoverable marked candidate that is deleted and validated absent before retry creates a fresh generation.
31. [EXPLICIT] Publisher suspension, package ineligibility, administrator conversion, registry quota zero, explicit disable, or user deletion must revoke publisher access while retaining runtime authority, project data, and artifacts as specified.
32. [EXPLICIT] Runtime credentials must use a separate project-scoped pull-only robot, remain protected Vesta authority for unattended pulls, and rotate transactionally without exposing credentials or using robot update/refresh.
33. [EXPLICIT] Provider-managed runtime registry entries must reject generic tenant registry change/delete while unrelated external registry entries remain manageable.
34. [EXPLICIT] `registry-info` must return only bounded non-secret provider, repository, publisher-metadata, quota, usage, health, and freshness fields and must never expose credentials, Harbor identifiers, internal endpoints, or raw errors.
35. [EXPLICIT] Application deployment must remain external build/push followed by immutable `repository@sha256:digest` preview, protected image pull, apply, health/probe, and drift verification through `v-docker`.
36. [CONSTRAINT] Harbor pushes, scans, API calls, and webhooks must never create Vesta desired state or trigger workload deployment or lifecycle mutation.
37. [EXPLICIT] CLI and panel operations must preserve Vesta authentication, CSRF, argument escaping, bounded job, audit, and human/JSON conventions; the panel must never accept or display publisher plaintext or age recipients.
38. [EXPLICIT] Managed health, metrics, usage, backup freshness, certificate state, and reconciliation failures must be bounded and classified as fresh, stale, or unavailable without promoting observations to authority.
39. [CONSTRAINT] Audit must record bounded provider/owner/quota/credential/backup/API outcomes without credentials, authorization data, raw payloads, image content, or unredacted Harbor output.
40. [EXPLICIT] Provider backup must be separate from tenant backups, consistent, versioned, hashed, encrypted, off-host recoverable, and include exact provider configuration, mappings, database, blob state, certificate configuration, and encrypted credentials.
41. [EXPLICIT] Validation-only restore must mutate nothing; applied restore and upgrade require explicit administrator confirmation, exact compatibility, pre-operation backup, health and authenticated-manifest checks, reconciliation, and preserved workload state.
42. [EXPLICIT] Disable/removal must default to plan-only, report dependencies and retained data, and must not purge Harbor data or mutate Docker images, containers, Vesta desired state, routes, volumes, revisions, or tenant backups.
43. [EXPLICIT] Documentation must clearly distinguish external registries, Vesta-managed Harbor runtime/publisher authority, and immutable Vesta deployment authority, including installation, recovery, quota, backup, revocation, retention, and framework-neutral deployment guidance.
44. [EXPLICIT] Development acceptance must demonstrate a verified idempotent install, unchanged external listener/DNS/firewall/certificate state, exact ingress isolation, authenticated push/pull, owner isolation, quota, separate usable credentials, immutable tenant deployment, revocation, outage isolation, backup validation, health, disable planning, rollback retention, and unchanged running workload state.
45. [CONSTRAINT] Release validation must use focused implementation tests and finish with the repository-owned limited readiness launcher plus `git diff --check`; broad standalone ShellCheck and unconstrained/full readiness execution are prohibited on constrained hosts.
46. [IMPLICIT] The audit must distinguish “feature implementation exists locally” from “managed provider is functionally accepted,” because local fixtures can pass while required live Task 10 end-to-end acceptance remains incomplete.
47. [IMPLICIT] The audit must identify stale or contradictory plan status text, because downstream agents can repeatedly act on obsolete blocker descriptions or obsolete execution handoffs rather than the latest approved specification and validation evidence.
48. [IMPLICIT] Recommendations must target the current live integration failure and evidence gaps rather than reopening the already resolved caller-selected-secret design decision, because the approved specification now defines Harbor-generated encrypted credential delivery.

## Findings By Plan Section

### Scope and release rules

Snapshot summary:

- The objective is an optional, pinned Harbor registry managed through Vesta authority for eligible Docker tenants, with digest-only deployment and no raw Docker or Harbor administration.

Findings:

- **Requirements Auditor**
  - `warning` — Maps broadly to [7]-[18] and [35]-[45]. The security and production boundaries are faithful, but the section does not incorporate the approved Harbor-generated, age-encrypted publisher credential contract in [22], [27], and [28], and it does not resolve the loopback-versus-Unix-socket specification mismatch noted in the baseline.
- **Assumptions Auditor**
  - `info` — Assumes failed transactional activation must restore Harbor to disabled and inactive. Requirements [10], [12], and [17] support fail-closed rollback, and the validation evidence confirms rollback deliberately restored that state.

### Fixed interfaces and state

Snapshot summary:

- The plan fixes administrator commands for installation, status, owner sync, backup/validate-only restore, and disable, plus owner-derived `v-docker` discovery and publisher actions.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [8], [10], [13], [18], [23], [25], [32], and [34], but its publisher interface is obsolete. The approved interface is `registry-publisher-rotate < age-recipient` from [27], not a caller-secret change action, and applied restore/upgrade authority required by [41] is absent.

### Transaction and convergence model

Snapshot summary:

- Vesta package/user state is desired authority; a bounded root-owned operation journal is durably recorded before Harbor mutation.

Findings:

- **Requirements Auditor**
  - `info` — Faithfully maps to [9], [25], [26], [38], and [39]. The exact three-state journal is more prescriptive than the source requirement, but it is a traceable implementation of idempotency and protected partial-state recovery rather than unrelated scope.

### Milestone 1: Disabled authority and entitlement - COMPLETE

Snapshot summary:

- Milestone 1 is marked complete and covers provider authority/status guards plus package entitlement and forward reconciliation.

Findings:

- **Requirements Auditor**
  - `info` — Maps to [10], [25], [26], and [46]. A completed disabled-mode authority can coexist with an unaccepted managed provider, provided later sections do not treat it as live Harbor acceptance.

### Task 1: Consolidate contract, provider authority, status, and endpoint guards

Snapshot summary:

- The task preserves earlier contract/harness and disabled-provider commits, then adds redacted read-only provider status and endpoint guards.

Findings:

- **Requirements Auditor**
  - `info` — Maps faithfully to [10], [13], [15], [18], [34], [38], and [39]. Its bounded status and fixed-route guards are supported by the baseline, although live external ingress acceptance remains owned by [44].

### Task 2: Simplify package entitlement and forward reconciliation

Snapshot summary:

- The task preserves package fields/defaults and measured-usage separation but removes experimental rollback/CAS machinery.

Findings:

- **Requirements Auditor**
  - `info` — Maps faithfully to [9], [25], [26], [38], and [39]. Forward recovery and conflict blocking are consistent with the required fail-closed package and quota authority.

### Milestone 1 acceptance

Snapshot summary:

- The plan records one aggregate focused run, one independent specification/security review, blocker-only corrections, and a milestone closeout record.

Findings:

- **Requirements Auditor**
  - `info` — Maps to focused validation in [45] and the implementation-versus-acceptance distinction in [46]. Its evidence is limited to disabled authority and entitlement and should not be reused as managed-provider acceptance.

### Milestone 1 record

Snapshot summary:

- The record claims durable journal publication before desired-state rename, rejection of stale journal/live-state mismatches, and quota mutation through the protected Unix socket.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [10], [25], [26], [38], and [45]. The record is traceable for local implementation, but deferred startup and owner-wide recovery mean its completion claim cannot establish the later live reconciliation requirements.

### Milestone 2: Verified installation and shared TLS ingress - COMPLETE

Snapshot summary:

- Milestone 2 is marked complete and covers release provenance plus transactional installation and ingress.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [8] and [11]-[17]. The code milestone may be complete, but calling the topology verified and runnable must be read as local implementation only: live ingress and full development acceptance under [44] remain unclaimed.
- **Assumptions Auditor**
  - `warning` — Assumes passing fixture tests and recording Milestone 2 complete establish a functionally accepted managed installation. Requirements [44] and [46] require live end-to-end acceptance, which remains incomplete.

### Task 3: Pin and verify the Harbor release

Snapshot summary:

- Release fixtures cover exact version, archive/image digests, Cosign identity/issuer and offline bundle, architecture, tag-only images, signature mismatch, and generated-config tampering.

Findings:

- **Requirements Auditor**
  - `info` — Maps faithfully to [11] and [12]. Archive checksum, signature identity, architecture, extraction safety, generator inventory, and digest pinning are all requirement-based.

### Task 4: Install transactionally with shared TLS ingress and rollback

Snapshot summary:

- Failure fixtures span prerequisites, disk, release, generation, Compose, migration, health, nginx validation/reload, socket ownership, certificate, and interruption.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [8], [9], and [12]-[18]. Transactional rollback is supported, but live exact-route acceptance is still unclear, and the plan's protected Unix socket requires an explicit compatibility decision against the source specification's fixed loopback wording.

### Milestone 2 acceptance

Snapshot summary:

- The plan records one focused aggregate run and one security/specification review covering provenance, installation, rollback, socket isolation, and ingress.

Findings:

- **Requirements Auditor**
  - `info` — Maps to [11]-[18] and [45]. It is valid as focused implementation review, not as a substitute for the development-host scenarios required by [44].

### Milestone 2 record

Snapshot summary:

- The record claims Harbor v2.15.0, installer/archive/bundle and ten image digests were pinned and verified, and unsafe generated topology was rejected.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [11]-[18], but several claims are only partly evidenced: the validation record does not independently enumerate all ten image digests or establish live exact ingress. Its explicit deferral of real-host evidence correctly leaves [44] open.

### Milestone 2 blocker correction

Snapshot summary:

- A correction replaced a synthetic image-only output with the official offline installer's canonical generator, validated the generator inventory/identity, converted runtime images to digests, and added durable storage/logging and container-created Unix socket behavior.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [11]-[18] and corrects traceable topology, ingress, publication, and rollback defects. The canonical-generator and complete digest-transformation claims remain unclear in the supplied technical evidence and should not be presented as independently proven.

### Milestone 3: Owner registry lifecycle - COMPLETE

Snapshot summary:

- Milestone 3 is marked complete and covers typed API access, owner reconciliation/quota/runtime credentials, publisher lifecycle/discovery, and revocation.

Findings:

- **Requirements Auditor**
  - `critical` — Maps nominally to [18]-[36], but the recorded lifecycle was built around the superseded caller-selected-secret and refresh assumption. It therefore does not establish compliance with [21], [22], [27], [28], [30], or the no-refresh portion of [32].

### Task 5: Add the allowlisted Harbor API adapter

Snapshot summary:

- Tests cover a fixed route/method allowlist, fixed Unix socket, bounded input/output, empty environment, curl-config authentication, redaction, status/timeouts, malformed JSON, and outage.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [18]-[21]. The fixed transport and bounded adapter are traceable, but the plan does not clearly record the final exact system-robot scope from [20] or the prohibition on routine update/refresh and bootstrap fallback from [21].
- **Commit/Runtime Evidence**
  - `critical` — Supplemental finding 9, **Test mirrors implementation instead of the approved permission contract**: The current spec and `.docs/contracts/harbor-provider.md` require system `project:create/list`, system `quota:read/update`, system-volume read, and wildcard-project `project:read/update` plus repository and robot actions. `func/vx/harbor/install.sh::_vx_harbor_install_integration_permissions` omits system `project:list` and wildcard `project:update`; `test/harbor/test-install.sh` and `test/harbor/test-upstream-robot-contract.sh` hard-code the same incomplete set. Thus focused tests cannot detect this spec/implementation drift.

### Task 6: Reconcile owners, quota, and runtime credentials

Snapshot summary:

- Reconciliation derives owner from Vesta state, creates one deterministic private project per eligible owner, sets byte quota from package authority, observes usage, and creates a pull-only runtime robot.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [20], [23], [25], [26], [29], and [32]. Project, quota, and identity separation are supported, but the plan omits exact project metadata [24] and its historical credential model does not demonstrate Harbor-generated one-time secrets with no update/refresh [21], [22], and [32].

### Task 7: Add publisher, discovery, and lifecycle revocation

Snapshot summary:

- Tenant discovery returns only derived origin/namespace/project/quota/usage/readiness; publisher change consumes a bounded secret from stdin and emits no secret.

Findings:

- **Requirements Auditor**
  - `critical` — Maps partially to [29], [31], [34], [35], and [36], but directly contradicts [22], [27], and [28] by consuming a publisher secret rather than one native X25519 age recipient and returning one encrypted Harbor-generated credential.
- **YAGNI Auditor**
  - `critical` — The caller-secret `registry-publisher-change` workflow created unsupported secret-selection, refresh, and recovery work that Harbor v2.15.0 cannot use. Requirements [22], [27]-[30] define the smaller supported workflow: accept one age recipient, create a marked child with a Harbor-generated secret, verify it, encrypt the one-time response, switch metadata, and delete the prior child.
- **Assumptions Auditor**
  - `warning` — Assumes publisher rotation consumes a caller-selected secret and emits no secret. Requirements [22], [27], [28], and [48] supersede this design: Harbor generates the one-time secret and Vesta must return only its encrypted age ciphertext.

### Milestone 3 acceptance

Snapshot summary:

- The single aggregate run stopped on a stale status assertion rather than completing cleanly.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [45] and [46], but the aggregate never reached a clean terminal result. Direct affected-suite passes do not erase that evidence gap, and the once-only rule has no source-requirement basis for preserving a known failed aggregate.

### Milestone 3 implementation record

Snapshot summary:

- The record claims protected typed adapters, deterministic owner mapping, quota/usage, pull-only runtime state, publisher rotation/disable, discovery, lifecycle hooks, and ordered locks.

Findings:

- **Requirements Auditor**
  - `critical` — Maps broadly to [18]-[36], but its secret-transport and rotation corrections validate the obsolete caller-secret design rather than the approved generated-secret/age-ciphertext contract in [22], [27], and [28]. The implementation record must distinguish superseded behavior from the corrected successor.

### Milestone 3 blocker correction

Snapshot summary:

- Secret-bearing API bodies were moved to an already-open descriptor/stdin, with fixtures checking argv, environment, logs, malformed/linked/oversized input, and failed responses.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [18], [23], [29], [30], [31], [34], and [39], but protecting a caller-supplied secret on a descriptor does not satisfy [22], [27], or [28]. This correction is historical evidence, not the current publisher solution.

### Milestone 3 rotation and tombstone lock correction

Snapshot summary:

- Runtime and publisher rotations now journal a nonsecret `pending-switch` before authority activation and recover through `pending-revoke` to `converged` without creating another robot.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [29]-[32], but its journals do not establish the required lost-create-response rule in [30]: a discoverable marked candidate must be deleted and validated absent before creating a fresh generation. It also remains attached to the superseded secret-refresh premise.

### Milestone 4: Operations and operator surfaces - COMPLETE

Snapshot summary:

- Milestone 4 is marked complete and covers health/observations, encrypted backup validation, disable lifecycle, minimal panel surfaces, and documentation.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [37]-[43], but completion conflicts with mandatory applied restore and controlled upgrade behavior in [41], complete encrypted credential backup content in [40], and the default plan-only removal boundary in [42].

### Task 8: Add health, encrypted backup validation, disable, and bounded operations

Snapshot summary:

- Health observes provider/API/certificate/storage, owner usage/quota, operations, and credential readiness as bounded, timestamped, redacted evidence rather than authority.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [38]-[42]. Health and validate-only restore are traceable, but excluding credential material conflicts with [40], validate-only restore is insufficient for [41], and the summary does not establish that disable/removal defaults to plan-only with complete dependent-workload and dependent-host evidence under [42].

### Task 9: Add essential panel surfaces and deployment documentation

Snapshot summary:

- Admin status is limited to mode, health, certificate, storage, backup age, and operation counts; tenant status is limited to registry origin/namespace/quota/usage/readiness and publisher guidance/action.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [34], [35], [37], and [43]. Bounded UI and workflow documentation are supported, but the obsolete publisher action means the plan does not demonstrate the current rule that the panel accepts or displays neither publisher plaintext nor age recipients.

### Milestone 4 acceptance

Snapshot summary:

- The plan records one nineteen-suite focused run and one security/specification review covering state, backup, disable, panel boundaries, and documentation.

Findings:

- **Requirements Auditor**
  - `warning` — Maps to [37]-[43] and [45], but local fixture success cannot close the live backup, health, disable, and workload-preservation checks required by [44].

### Milestone 4 record

Snapshot summary:

- The record claims redacted provider/owner observations, encrypted age backups, ciphertext-only Vesta backup persistence, validate-only restore with unsupported apply, transactional retained-data disable, panel status/actions, and workflow/recovery documentation.

Findings:

- **Requirements Auditor**
  - `critical` — Maps partially to [38]-[43], but explicitly deferring restore apply and automated upgrade contradicts [41]. Its backup description also does not demonstrate inclusion of encrypted credentials required by [40].

### Milestone 5: Development acceptance and release closure

Snapshot summary:

- Milestone 5 is explicitly marked `BLOCKED — PRODUCT`, despite Task 11 being complete and prior milestones being recorded complete.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [3]-[5], [44]-[48], but states the wrong current blocker. The approved generated-secret contract is supported; a protected marker transaction completed integration. The final successor reached health and then failed during uninstrumented integration without a recorded final error, so Harbor is disabled because transactional activation rolled back, not because Harbor cannot satisfy [22], [27], and [28].
- **YAGNI Auditor**
  - `critical` — Classifying Milestone 5 as product-blocked by Harbor's caller-secret behavior perpetuates an already resolved design branch. The structured evidence shows a corrected marker-only transaction completed integration successfully, while only the later uninstrumented successor lacks a precise error. The smaller response is targeted instrumentation around the integration phases, not another credential-model redesign.
- **Assumptions Auditor**
  - `warning` — Assumes Harbor v2.15.0 credential behavior remains a product blocker. The baseline and technical evidence show that the generated-credential design was approved, implemented, passed a clean local aggregate, and later completed a protected delegated project/robot integration probe.
- **Commit/Runtime Evidence**
  - `info` — Supplemental finding 11, **Why “nonfunctional” is accurate only at the product-acceptance level**: Harbor itself reached ten healthy containers, and an instrumented integration probe succeeded. However the provider never stayed managed, no successful install audit exists, the current focused aggregate fails, the current limited readiness gate did not pass, and the live owner/quota/publisher/push-pull/deploy/revocation/outage/backup/disable scenarios remain unclaimed. Describe this as “substantially implemented but not functionally accepted,” not “Harbor cannot run.”

### Task 10: Perform development-host acceptance

Snapshot summary:

- A clean local aggregate run and exact staged payload/hash verification are recorded; staging, release generation, isolated startup, socket, health, and authenticated bootstrap were exercised.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [44] and [46], but its caller-secret replacement and HTTP 403 refresh observations are historical evidence that led to the now-approved no-refresh design in [21], [22], [27], and [28]. Treating them as the active product blocker is stale. The actual latest failing integration step is unknown because the final successor was uninstrumented.
- **Assumptions Auditor**
  - `warning` — Assumes development acceptance is still blocked before integration credential establishment. Approved evidence shows a corrected marker-only transaction created and validated the integration identity and completed its delegated probe; the later uninstrumented successor failed at an unidentified integration point.
  - `warning` — Assumes the final failure proves Harbor itself is nonfunctional. Harbor reached a healthy ten-container state and integration succeeded in an instrumented predecessor; what remains unaccepted is the complete transactional activation and Task 10 workflow, not Harbor's basic ability to run.
  - `critical` — Resolved assumption unresolved-1: Read-only inspection confirmed that the final e3b2b19d rollback evidence contains phase markers only through health and a generic transaction-rolled-back event. No exact trace or redacted integration error exists, so the low-level cause cannot be attributed to a previously corrected defect, the stale caller-secret blocker, or another specific failure. The supported conclusion is limited to: integration did not complete, transactional activation failed closed, and rollback deliberately left Harbor disabled.
- **Commit/Runtime Evidence**
  - `critical` — Supplemental finding 2, **Repeated live failure**: The development authority audit contains 20 failed `provider-install` events: 19 `transaction-rolled-back` and one `cleanup-pending`; it contains no successful provider-install event. This is why no managed authority was ever published.
  - `info` — Supplemental finding 3, **Current development state**: A read-only check on the development host at `[REDACTED:development-ip]` found provider `MODE=disabled`, `PINNED_VERSION=v2.15.0`, `RUNNING_VERSION=null`, `ORIGIN=null`, service inactive/disabled, no proxy socket, and zero `vesta-harbor` containers. This verifies the rollback state rather than inferring it from old prose.
  - `critical` — Supplemental finding 4, **Final uninstrumented evidence is insufficient**: The retained final rollback `[REDACTED:rollback-path]/provider-install.log` contains only successful phase markers through `PHASE=health`; it contains no exact integration step, HTTP status, redacted response, or error. The durable audit records only `transaction-rolled-back`. The exact low-level final failure therefore cannot be identified from retained evidence.
  - `critical` — Supplemental finding 5, **Instrumented versus uninstrumented discrepancy**: The 08446067 retained uninstrumented log stops after `PHASE=health`. A later traced run on the same staged revision records `PHASE=integration` and then fails at nginx candidate validation, with protected function markers showing `_vx_harbor_install_integration_configure` and `_vx_harbor_install_delegated_probe` both returning 0. Commit e3b2b19d fixes that nginx/Vesta-panel reload defect, yet the next uninstrumented run again stops before `PHASE=integration`. This strongly suggests an integration timing/readiness or observability-sensitive defect, but it does not prove the exact failing call.
  - `critical` — Supplemental finding 6, **Static observability gap**: `func/vx/harbor/install.sh` defines `_vx_harbor_install_phase() { :; }`; product code emits no phase evidence by itself. Bootstrap curl calls suppress stderr, many validation branches return only 1/75, and `bin/v-install-harbor-registry` emits only a generic rollback message. Rollback removes the transaction staging/journal on successful cleanup. Ad hoc instrumentation changed the timing of the only successful integration run, so the diagnostic method itself may mask a race.
  - `warning` — Supplemental finding 7, **Readiness/race inference**: After generic Harbor health succeeds, the installer immediately performs bootstrap and newly-created credential operations. Bootstrap retries occur three times without delay; `_vx_harbor_install_integration_probe` is single-shot; delegated project/robot calls and credential probes are not wrapped in a bounded readiness/backoff loop. Because traced execution succeeded and uninstrumented execution repeatedly failed, insufficient integration-specific readiness is the leading inference, not a proven root cause.

### Task 11: Final release review and closeout

Snapshot summary:

- The task uses the repository's limited production-readiness launcher and prohibits broad standalone ShellCheck, direct canonical/full gate execution, or an unlimited override.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [3], [45], and [46], but its claimed final limited-readiness pass applies to an older revision. The relevant generated-credential successor run exited 143 after resource exhaustion and is not a pass, so current release closure lacks required evidence.
- **YAGNI Auditor**
  - `warning` — Running release closeout and repeatedly correcting release-gate findings before Task 10 live acceptance was complete produced evidence for obsolete revisions and must now be repeated for the successor. Requirement [45] says to finish with the limited readiness launcher. The smaller sequence is to complete Task 10 first, then run one final closeout gate against the exact accepted revision.
- **Assumptions Auditor**
  - `warning` — Assumes the relevant final limited readiness launcher passed. The successor validation records exit 143 after resource exhaustion, so requirement [45] remains unmet for the generated-credential revision.

### Requirement traceability

Snapshot summary:

- A table maps sixteen requirements to Tasks 1–11 and test/evidence sources.

Findings:

- **Requirements Auditor**
  - `critical` — The existing sixteen-row mapping is stale against [20]-[22], [27]-[30], [40]-[42], and [44]-[48]. It conflates fixture coverage with host acceptance and preserves the obsolete caller-secret blocker instead of tracing the approved generated-credential successor.
- **Assumptions Auditor**
  - `info` — Assumes local implementation evidence and live functional acceptance are distinct. Requirements [44] and [46] support that distinction: substantial implementation exists, but managed activation and the remaining tenant, quota, deployment, revocation, outage, backup, health, and disable workflows are still unclaimed.

### Test ownership and cadence

Snapshot summary:

- Task-specific Harbor/PHP tests run during implementation; the aggregate Harbor runner is assigned once per milestone.

Findings:

- **Requirements Auditor**
  - `critical` — Maps partly to [45], but the once-only aggregate policy is unsupported scope that preserves known failed evidence. The current successor also lacks a passing limited readiness run, so the cadence does not satisfy the release-validation requirement.
- **YAGNI Auditor**
  - `warning` — The once-only aggregate-run policy is unnecessary process machinery that deliberately preserves a failed Milestone 3 aggregate and prevents clean post-correction evidence. Requirements [44]-[46] require credible acceptance, not artificial run scarcity. Use direct tests during correction and one clean aggregate after the final correction to the milestone.
- **Assumptions Auditor**
  - `warning` — Assumes direct affected-suite passes and a once-only aggregate cadence provide adequate successor evidence after material corrections. The record retains a nonpassing Milestone 3 aggregate and the latest required limited gate did not pass, leaving agents without a single current, coherent acceptance baseline.
- **Commit/Runtime Evidence**
  - `critical` — Supplemental finding 8, **Current focused aggregate regression**: A fresh `bash test/harbor/run-focused.sh` fails after `Harbor fixture tests passed` with `candidate discovery after lost response returned 400, expected 200`. The failing source-parity request in `test/harbor/test-upstream-robot-contract.sh` still sends `page_size=1000` while commit `5725323e` changed the fake Harbor API and runtime adapters to a maximum page size of 100. The direct install, API, and ingress tests all pass. The validation record explicitly says the aggregate was not rerun after post-f41990e9 live corrections, allowing this regression to escape.
  - `warning` — Supplemental finding 10, **Live defects trace to inaccurate fixtures and late integration**: Post-clean-run live fixes were required because Harbor rejected `page_size=1000`, the adapter expected the wrong socket ownership, and ingress edited Vesta panel nginx while testing/reloading Debian nginx. Each behavior was previously accepted or abstracted away by local fixtures. The plan delayed real-host evidence until Milestone 5 after Milestones 1-4 and release closeout had already been marked complete.

### Preserved implementation evidence

Snapshot summary:

- The plan inventories baseline, harness/contract, provider authority, package experiments, earlier/fresh development staging, release-gate corrections, and final-review corrections by commit identifiers.

Findings:

- **Requirements Auditor**
  - `critical` — Maps to [2], [3], and [46], but does not correctly order the current evidence: the corrected generated-credential implementation and successful marker transaction supersede the historical caller-secret product blocker, while the later uninstrumented successor still failed integration and rolled back.
- **YAGNI Auditor**
  - `warning` — Keeping superseded experiments, blocker narratives, commit inventories, current status, and executable instructions together in the active plan makes historical decisions look actionable and contributes to repeated work. Requirement [47] requires stale status to be distinguishable. Keep the active plan to current requirements, unresolved evidence, and next actions; move the correction chronology to the validation record and reference it.
- **Commit/Runtime Evidence**
  - `warning` — Supplemental finding 1, **Branch scale and churn**: From parent `07f5b30a` through HEAD `1f308b70`, the work spans 87 commits over 22 hours 12 minutes (`2026-08-08T14:30:58+10:00` to `2026-08-09T12:43:08+10:00`): 9 feature, 40 fix, 13 test, and 25 documentation commits. The net diff is 118 files and 13,171 insertions. Eighty-four commit subjects mention Harbor and eleven claim close/finalize work. This supports the diagnosis of premature closeout and correction loops.

### Deferred operational hardening

Snapshot summary:

- Deferred non-blockers include richer Harbor UI, automated upgrades, automated restore apply, expanded metrics, optional scanning, exhaustive documentation assertions, and automatic production deployment.

Findings:

- **Requirements Auditor**
  - `critical` — Most listed UI, metrics, scanning, and automation deferrals are permissible, but deferring applied restore and controlled upgrade is not: [41] makes both first-release requirements unless separately approved.
- **Assumptions Auditor**
  - `warning` — Assumes restore apply and controlled upgrade can be deferred from the first release. Requirement [41] requires both behaviors, and the technical evidence classifies validate-only restore as incompatible with the approved specification absent separate scope approval.

### Current deferred boundary and next action

Snapshot summary:

- The plan states Task 10 and Milestone 5 remain product-blocked because the approved caller-selected publisher-secret design is incompatible with observed Harbor v2.15.0 robot behavior at the approved privilege boundary.

Findings:

- **Requirements Auditor**
  - `critical` — Maps directly to [4], [5], [44], [47], and [48], but gives a superseded diagnosis and recommendation. The product decision in [22], [27], and [28] is already approved. The current action is to instrument and isolate the final integration failure, correct the DNS discrepancy, rerun incomplete host acceptance, and obtain a passing current-revision limited readiness result.
- **YAGNI Auditor**
  - `critical` — The proposed product review of caller-selected publisher secrets or expanded routine-administrator authority is obsolete work. Requirements [20]-[22], [27]-[30], and [48] already approve Harbor-generated one-time secrets encrypted to an age recipient. The smaller path is to diagnose the final integration attempt within that approved design, stage one successor, and rerun only incomplete Task 10 checks.
- **Assumptions Auditor**
  - `warning` — Assumes another publisher-secret product decision is required before progress can continue. Requirements [22], [27], [28], and [48] already settle that decision; repeating this stale blocker diverts work from instrumenting and correcting the current integration failure.
  - `warning` — Assumes the DNS discrepancy explains the latest rollback. The evidence only establishes that ordinary resolution targets another address while pinned hostname/SNI TLS succeeds; it does not connect DNS to the final post-health integration failure.
- **Commit/Runtime Evidence**
  - `info` — Supplemental finding 12, **DNS is independent**: The integration adapter uses the protected local socket, and the final failure occurred before public ingress publication. The development resolver discrepancy blocks unpinned external client acceptance but is not evidence for the post-health integration rollback.

### Execution handoff

Snapshot summary:

- The source ends with an embedded execution instruction to use milestone-driven implementation and begin at Milestone 1, even though Milestones 1–4 are already marked complete and Milestone 5 is the active blocked boundary.

Findings:

- **Requirements Auditor**
  - `critical` — Contradicts [47] and [48]. Restarting at Milestone 1 has no current baseline support and can cause repeated work; the active boundary is the generated-credential successor's uninstrumented integration failure plus incomplete Task 10 and release evidence.
- **YAGNI Auditor**
  - `critical` — Restarting milestone-driven implementation at Milestone 1 repeats four milestones already recorded complete and invites agents to reopen settled architecture. Requirements [4], [5], [47], and [48] call for investigating the current live failure. Replace this handoff with one bounded task beginning at the exact failing integration phase.
- **Assumptions Auditor**
  - `warning` — Assumes execution should restart at Milestone 1. Milestones 1–4 are already recorded complete and Milestone 5 is the active boundary; this contradictory handoff plausibly causes agents to repeat reviews and corrections instead of isolating the latest Task 10 failure.

## Requirement Gaps

- **Requirement 20 — `critical`:** The routine integration identity must be the approved least-privilege system robot with system scope `/`, wildcard project scope `*`, exact approved project/quota/volume/repository/robot create-read-list-delete actions, and no robot update/refresh authority.
  - Gap: The plan preserves the historical rejected scope and refresh blocker but does not clearly publish the corrected exact routine scope as current authority.
- **Requirement 21 — `critical`:** Routine lifecycle must use child create, verify, metadata switch, validated delete, and no robot update, refresh, disable, or bootstrap-administrator fallback.
  - Gap: Rotation sections cover create, verify, switch, and delete, but Task 10 still treats failed refresh as a blocker and does not establish the no-refresh/no-bootstrap-fallback lifecycle.
- **Requirement 22 — `critical`:** Harbor-generated one-time robot secrets are the approved v2.15.0 contract; Vesta must not attempt caller-selected creation secrets or later secret refresh.
  - Gap: The plan's fixed interface, Task 7, Task 10 blocker, and next action retain the exact caller-secret and refresh design this requirement supersedes.
- **Requirement 24 — `warning`:** Project creation must use only Harbor-supported private metadata, exactly `{"public":"false"}`, and must not invent unsupported metadata keys.
  - Gap: No sanitized plan section states or tests the exact supported project-creation payload.
- **Requirement 27 — `critical`:** Publisher rotation must be `v-docker registry-publisher-rotate < age-recipient`, accepting exactly one bounded validated native X25519 age recipient on stdin—not a publisher secret.
  - Gap: The plan specifies a publisher-change action consuming a secret and never adopts the approved rotate/age-recipient interface.
- **Requirement 28 — `critical`:** Harbor must generate the publisher secret once; Vesta must verify it and stream only one complete ASCII-armored age ciphertext to stdout, with no plaintext durability in files, state, journals, backups, logs, audit, argv, environment, JSON, or HTML.
  - Gap: No plan section covers encrypted one-time delivery; existing secret-transport corrections protect the obsolete caller-supplied-secret flow.
- **Requirement 30 — `critical`:** A lost one-time create response must leave a discoverable marked candidate that is deleted and validated absent before retry creates a fresh generation.
  - Gap: The plan journals rotation crashes but does not specify candidate discovery, validated deletion after a lost response, and fresh-generation retry.
- **Requirement 32 — `critical`:** Runtime credentials must use a separate project-scoped pull-only robot, remain protected Vesta authority for unattended pulls, and rotate transactionally without exposing credentials or using robot update/refresh.
  - Gap: Separation and transactional switching are covered, but the plan's active blocker still assumes secret refresh is required.
- **Requirement 33 — `critical`:** Provider-managed runtime registry entries must reject generic tenant registry change/delete while unrelated external registry entries remain manageable.
  - Gap: No sanitized plan section explicitly implements or validates this authority guard.
- **Requirement 37 — `warning`:** CLI and panel operations must preserve Vesta authentication, CSRF, argument escaping, bounded job, audit, and human/JSON conventions; the panel must never accept or display publisher plaintext or age recipients.
  - Gap: General panel secrecy is covered, but the plan does not trace the current age-recipient CLI-only boundary and still describes an obsolete publisher action.
- **Requirement 40 — `critical`:** Provider backup must be separate from tenant backups, consistent, versioned, hashed, encrypted, off-host recoverable, and include exact provider configuration, mappings, database, blob state, certificate configuration, and encrypted credentials.
  - Gap: Task 8 explicitly excludes secret credentials and keys; no replacement design demonstrates inclusion of the required encrypted credential authority.
- **Requirement 41 — `critical`:** Validation-only restore must mutate nothing; applied restore and upgrade require explicit administrator confirmation, exact compatibility, pre-operation backup, health and authenticated-manifest checks, reconciliation, and preserved workload state.
  - Gap: The plan implements validate-only restore but explicitly defers restore apply and automated upgrade, contradicting the approved first-release scope.
- **Requirement 42 — `warning`:** Disable/removal must default to plan-only, report dependencies and retained data, and must not purge Harbor data or mutate Docker images, containers, Vesta desired state, routes, volumes, revisions, or tenant backups.
  - Gap: Retained-data disable is covered, but the plan does not clearly establish plan-only default behavior or complete dependency evidence including accepted workload references and dependent hosts.
- **Requirement 44 — `critical`:** Development acceptance must demonstrate a verified idempotent install, unchanged external listener/DNS/firewall/certificate state, exact ingress isolation, authenticated push/pull, owner isolation, quota, separate usable credentials, immutable tenant deployment, revocation, outage isolation, backup validation, health, disable planning, rollback retention, and unchanged running workload state.
  - Gap: The plan acknowledges that managed activation and almost all end-to-end tenant, backup, disable, and outage checks remain unclaimed; the DNS discrepancy also remains unresolved.
- **Requirement 45 — `critical`:** Release validation must use focused implementation tests and finish with the repository-owned limited readiness launcher plus `git diff --check`; broad standalone ShellCheck and unconstrained/full readiness execution are prohibited on constrained hosts.
  - Gap: The relevant successor's limited readiness run exited 143 under resource exhaustion. The recorded pass belongs to an older revision.
- **Requirement 48 — `critical`:** Recommendations must target the current live integration failure and evidence gaps rather than reopening the already resolved caller-selected-secret design decision, because the approved specification now defines Harbor-generated encrypted credential delivery.
  - Gap: The plan's proposed next action does the opposite: it requests another publisher-secret product decision instead of instrumenting the unknown final integration failure and closing remaining host evidence.

## Audit Summary

| Category | Critical | Warning | Info | Total |
| --- | ---: | ---: | ---: | ---: |
| Requirements Traceability | 19 | 10 | 7 | 36 |
| YAGNI Compliance | 4 | 3 | 0 | 7 |
| Assumption Audit, including resolved assumptions | 1 | 11 | 2 | 14 |
| Commit/Runtime Evidence | 6 | 3 | 3 | 12 |
| **Section findings total** | **30** | **27** | **12** | **69** |
| Requirement gaps, reported separately | 13 | 3 | 0 | 16 |

Harbor remains disabled for a proven fail-closed reason: none of the recorded development `provider-install` attempts published managed authority; the final successor reached Harbor health, did not complete integration, and the transaction deliberately rolled back to disabled/inactive state. The exact low-level final integration failure is unobservable from the retained evidence: the final log ends after the health phase and the durable audit contains only a generic rollback event. It cannot reliably be attributed to a prior fixture defect, the superseded caller-secret design, DNS, or any other specific call.

The evidence supports describing the product as **substantially implemented but not functionally accepted**. Harbor itself reached ten healthy containers and an instrumented integration probe succeeded, but the provider never remained managed; the current focused aggregate regresses; the current-revision limited readiness gate did not pass; and the required live owner, quota, publisher, immutable deploy, revocation, outage, backup, health, and disable scenarios remain unclaimed.

The roughly 24-hour delivery cycle is explained by evidence of 87 commits over 22 hours 12 minutes, including 40 fix commits and eleven close/finalize claims; late real-host integration after Milestones 1–4 were marked complete; fixtures that accepted behaviors rejected on the live host; repeated premature closeout; and stale active-plan text that keeps redirecting agents toward an already resolved credential-design branch. The next bounded work should add persistent redacted phase/error evidence, isolate the post-health integration failure within the approved Harbor-generated/age-encrypted design, correct the independent DNS discrepancy, rerun only incomplete Task 10 acceptance, and finish with one passing current-revision limited readiness result.

## Resolved Assumptions

### unresolved-1: Task 10: Perform development-host acceptance

- Question: Can the protected transaction trace or exact redacted error from the final e3b2b19d staging attempt be supplied so the current integration failure can be identified?
- User answer summary: Retained evidence has health-phase markers and a generic rollback event but no exact integration error; the low-level cause is unavailable.
- Result: `critical` — Read-only inspection confirmed that the final e3b2b19d rollback evidence contains phase markers only through health and a generic transaction-rolled-back event. No exact trace or redacted integration error exists, so the low-level cause cannot be attributed to a previously corrected defect, the stale caller-secret blocker, or another specific failure. The supported conclusion is limited to: integration did not complete, transactional activation failed closed, and rollback deliberately left Harbor disabled.

## Open Questions

- **unresolved-2 — Task 5: Add the allowlisted Harbor API adapter:** Was the protected Unix socket explicitly approved as satisfying or replacing the specification's fixed loopback-only transport requirement?
  - Why open: No separate approval was supplied after clarification, so the transport-contract discrepancy remains unresolved.
- **unresolved-3 — Deferred operational hardening:** Is there an approved scope decision outside the supplied sources that defers applied restore and controlled upgrade from this release?
  - Why open: No separate scope approval was supplied after clarification, so the plan/specification conflict remains unresolved.

## Sensitive Content Handling

- The development hostname, authorized development address, alternate DNS-resolved address, and rollback archive path remain redacted.
- No API keys, bearer tokens, passwords, private keys, publisher secrets, runtime credentials, bootstrap credentials, integration credentials, authorization headers, or protected payloads are reproduced.
- Supplemental evidence is preserved in substance, but the development host address and protected rollback path are represented as `[REDACTED:development-ip]` and `[REDACTED:rollback-path]`.
- Secret-related filenames, fixed product paths, commit identifiers, route names, API behavior, and bounded nonsecret operation metadata are retained only where needed for audit traceability.
- Findings rely on the sanitized snapshot and structured evidence; the raw plan, approved specification, and development validation record were not copied into this artifact.
