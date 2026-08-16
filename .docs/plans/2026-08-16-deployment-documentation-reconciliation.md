# Deployment Documentation Reconciliation Implementation Plan

> **For agentic workers:** Execute inline because this is one integrated
> documentation contract: the release runbook, environment-neutral examples,
> historical evidence, and documentation tests must agree in one commit. Steps
> use checkbox (`- [x]`) syntax for tracking.

**Goal:** Provide one current, environment-neutral deployment protocol for the
Vesta control plane and for arbitrary container workloads managed by Vesta.

**Architecture:** Separate host installation of repository files from tenant
application delivery. Standing guides define reusable requirements; dated
records retain technical evidence while replacing private environment and
application identity with semantic role labels. A repository test prevents
ecosystem application names and environment endpoint addresses from returning
to Vesta-owned Markdown.

**Tech Stack:** Markdown, Bash documentation-contract tests, Git.

---

### Task 1: Define the Vesta control-plane release procedure

**Files:**
- Create: `.docs/user-guides/vesta-control-plane-releases.md`
- Modify: `.docs/README.md`
- Modify: `README.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`
- Modify: `SECURITY.md`

- [x] **Step 1: Add an operator runbook that distinguishes Vesta source
  installation from container image delivery.**

  Document release identity, required validation, environment authorization,
  staged payload manifests, host mapping to `/usr/local/vesta`, release and
  project locks, rollback roots, exact ownership/modes, migrations, scoped
  service restarts, post-install acceptance, cleanup, and retained evidence.

- [x] **Step 2: Make the runbook the canonical link from every standing index.**

  Replace the undefined “normal release process” wording and state explicitly
  that OCI images belong only to managed workloads.

### Task 2: Reconcile current deployment status and workflow

**Files:**
- Modify: `docs/container-orchestration.md`
- Modify: `.docs/user-guides/docker-compose-projects.md`
- Modify: `.docs/user-guides/vesta-managed-harbor.md`
- Modify: `.docs/user-guides/vesta-managed-harbor-operator.md`
- Modify: `.docs/contracts/compose-self-service-deployment.md`
- Rename: the former application-specific 2026-08-11 acceptance filename to
  `.docs/validation/2026-08-11-managed-harbor-application-release.md`

- [x] **Step 1: Align every status banner with accepted development delivery
  and separately deferred production mutation.**

- [x] **Step 2: Rewrite the accepted application record as an
  application-neutral proof of the reusable protocol.**

  Preserve the transaction and boundary evidence, but replace repository,
  owner, project, endpoint, route, and immutable artifact identities with
  semantic evidence fields.

- [x] **Step 3: State the complete recurring transaction.**

  Require clean source, external build/test, fresh registry discovery,
  immutable digest, preview-bound pull, explicit apply approval, health,
  readiness, drift, public acceptance when applicable, rollback preview, and
  publisher revocation.

### Task 3: Remove environment and ecosystem identity from Vesta documentation

**Files:**
- Modify: `.docs/plans/*.md`
- Modify: `.docs/status/*.md`
- Modify: `.docs/validation/*.md`
- Modify: `.docs/audits/*.md`
- Modify: `tests/playwright/README.md`
- Modify: other tracked Vesta Markdown found by the identity scan

- [x] **Step 1: Replace named hosts, endpoint addresses, SSH identities, and
  application-specific owners/projects with role variables.**

  Use names such as `VESTA_HOST`, `STAGING_TARGET`, `STAGING_JUMP`,
  `APP_OWNER`, `APP_PROJECT`, and `REGISTRY_ORIGIN`. Retain `127.0.0.1` and
  `0.0.0.0` only where they express a functional loopback or listener contract.

- [x] **Step 2: Reframe workload-specific evidence as generic compatibility
  workload evidence.**

  Preserve revision, health, backup, rollback, secret, route, and policy facts
  without retaining private application names.

- [x] **Step 3: Rename environment-specific plan and validation filenames and
  repair all links.**

### Task 4: Add regression coverage and validate

**Files:**
- Modify: `test/test_compose_docs.sh`
- Modify: `test/harbor/test-doc-contract.sh`

- [x] **Step 1: Update documentation-contract expectations for the generic
  acceptance record and current status.**

- [x] **Step 2: Add a tracked-Markdown scan.**

  Fail when Vesta-owned Markdown contains a non-Vesta `*-vxapp` application
  name, known ecosystem identity, private-network endpoint, or documentation
  address used as a fixed deployment target. Exempt functional loopback and
  wildcard listener addresses.

- [x] **Step 3: Run focused validation.**

  Run `bash -n test/test_compose_docs.sh test/harbor/test-doc-contract.sh`,
  `bash test/test_compose_docs.sh`, `bash test/harbor/test-doc-contract.sh`,
  link and identity scans, and `git diff --check`. Expected result: all pass
  with no stale links or prohibited environment/application identities.

- [x] **Step 4: Commit the reconciled documentation.**

  Commit all documentation, test, and rename changes together with message
  `docs(deploy): make release guidance environment neutral`.
