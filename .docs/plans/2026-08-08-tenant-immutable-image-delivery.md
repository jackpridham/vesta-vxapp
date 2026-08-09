# Tenant Immutable Image Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `$milestone-driven-implementation` because this is a security-sensitive, multi-repository product milestone. Complete the Vesta authority milestone and its independent specification review before host rollout; use focused tests during implementation and reserve full affected-system closeout for the end.

**Goal:** Let an eligible Vesta tenant build in CI, push an immutable registry digest, pull that exact bounded image through `v-docker`, and preview/apply its own `standard` project without raw Docker or a human Debian step.

**Architecture:** Add one owner-derived, preview-bound `image-pull` broker operation backed by a dedicated immutable-only Vesta adapter. The adapter verifies the exact protected preview evidence and revision, requires the image in that preview, verifies the registry manifest and bounded Linux/approved-architecture image size before Docker mutation, pulls with the owner's protected registry configuration, and records root-controlled registry-pull provenance. Standard-project resolution accepts registry images only when the submitted reference is itself immutable and matching pull provenance exists; tag/local-image references continue to require expiring administrator approval. Legacy workload builds remain off-host, the new workload uses generic `standard` v2, and exact accepted-revision compatibility preserves legacy production without authorizing new candidates until a separately authorized migration window.

**Tech Stack:** Bash, Docker CLI manifest/image APIs, jq, Vesta state, SSH, Compose, Python workload builder, shell namespace fixtures.

---

## Product milestones

1. Vesta tenant immutable image delivery and local-image authority correction.
2. Development host onboarding and a standard-profile Legacy workload deployment rehearsal.
3. Cross-repository deployment documentation and production account readiness without production workload mutation.

### Task 1: Specify broker and image-authority behavior

**Files:**
- Modify: `.docs/contracts/compose-shell-access.md`
- Modify: `.docs/contracts/compose-images.md`
- Modify: `.docs/contracts/compose-self-service-deployment.md`
- Modify: `docs/container-orchestration.md`
- Modify: `DOCKER_ORCHESTRATION_DEPLOYMENT.md`

- [ ] **Step 1: Add the tenant command contract**

Add this exact catalog form:

```text
image-pull PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION IMAGE@sha256:DIGEST
```

State that the broker derives the owner, fixes profile authority to `standard`, requires exact unexpired add/change preview evidence and revision, verifies that the image occurs in that preview, accepts no tag, URL, owner, actor, platform, Docker option, or credential argument, and uses only the owner's protected registry configuration.

- [ ] **Step 2: Separate pull, approval, and deployment language**

Document these independent facts:

```text
immutable registry digest -> tenant may request bounded owner-scoped pull
local archive or tag       -> administrator load plus expiring local approval
already delivered image    -> tenant preview/apply/deploy for standard only
legacy-admin-app/admin-approved -> administrator-only; never accepted by v-docker
```

- [ ] **Step 3: Define image admission limits**

Require manifest inspection before pull, one unambiguous Linux/approved-architecture manifest, a bounded layer count, a positive aggregate config/layer byte count no greater than `VX_COMPOSE_IMAGE_MAX_BYTES`, a fixed pull timeout, exact post-pull digest/platform/size verification, root-controlled owner-scoped registry-pull provenance, and started/terminal redacted audit output.

### Task 2: Write failing focused tests

**Files:**
- Modify: `test/compose/fixtures/shell-broker-namespace.sh`
- Modify: `test/compose/test-images.sh`
- Modify: `test/compose/test-cli-surface.sh`
- Modify: `test/compose/test-shell-access-root-integration.sh`
- Create: `test/compose/test-tenant-image-pull.sh`

- [ ] **Step 1: Add exact broker dispatch coverage**

Add an executable fake `v-pull-docker-project-image` and require:

```text
v-docker image-pull app PREVIEW SOURCE CANDIDATE REVISION registry.example/app@sha256:<64 lowercase hex>
  -> v-pull-docker-project-image alice alice app PREVIEW SOURCE CANDIDATE REVISION registry.example/app@sha256:<digest>
```

Reject tags, uppercase/malformed digests, extra arguments, option injection, embedded credentials, URLs, malformed preview evidence, and owner arguments before the fake adapter runs.

- [ ] **Step 2: Add immutable pull helper tests**

Extend the fake Docker implementation with single-platform and index manifest fixtures containing config/layer sizes. Prove that immutable pull:

```text
- rejects tags before Docker image pull;
- rejects images absent from the exact verified preview and stale/expired/replaced preview evidence;
- rejects missing, ambiguous, wrong-platform, zero-size, malformed, and oversized manifests;
- performs manifest inspection before image pull;
- verifies the post-pull immutable reference, image ID, OS, and architecture;
- writes only secure registry-pull provenance and bounded redacted audit evidence.
```

- [ ] **Step 3: Add standard resolver regression tests**

Prove that a standard candidate:

```text
- accepts a pulled and recorded exact repository digest;
- rejects an unrecorded exact digest;
- rejects a tag carrying a Docker-generated RepoDigests entry without local approval;
- accepts that tag only with matching unexpired administrator approval;
- permits accepted-revision refresh only for an identical exact legacy or schema-2 tuple, without authorizing a new candidate or synthesizing pull provenance.
```

- [ ] **Step 4: Run failing tests**

Run:

```bash
bash test/compose/test-images.sh
bash test/compose/test-shell-access.sh
bash test/compose/test-cli-surface.sh
```

Expected: failures identify the missing immutable adapter, broker operation, and standard resolver authority checks.

### Task 3: Implement immutable image delivery

**Files:**
- Create: `bin/v-pull-docker-project-image`
- Modify: `bin/v-run-user-docker-command`
- Modify: `func/vx/compose/images.sh`
- Modify: `func/vx/compose/deployment.sh`
- Modify: `func/vx/compose/registry.sh`

- [ ] **Step 1: Add immutable reference validation**

Implement:

```bash
vx_compose_image_reference_is_immutable() {
    vx_compose_image_reference_is_valid "$1" \
        && [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,181}@sha256:[a-f0-9]{64}$ ]]
}
```

Use the repository parser to preserve the existing 255-byte total reference bound.

- [ ] **Step 2: Add bounded manifest admission**

Implement a helper that calls owner-scoped `docker manifest inspect` using the protected registry config, selects exactly one `linux/$VX_COMPOSE_ALLOWED_ARCHITECTURE` manifest when the reference is an index, inspects the selected child digest, and sums `.config.size` plus every `.layers[].size`. Reject non-integer, negative, zero, overflowing, malformed, ambiguous, or over-limit totals before `docker image pull`.

- [ ] **Step 3: Add immutable owner pull**

Implement a preview-bound immutable pull that validates owner/project/evidence/reference, acquires locks in the order owner access -> project -> global tenant pull -> owner registry, verifies the protected preview and exact image occurrence, runs bounded manifest admission, pulls exactly the digest with raw output suppressed, inspects it, requires the matching repository digest and approved platform/size, atomically records root-owned `0600` registry-pull provenance, audits started and terminal outcomes, and releases every lock on every path.

- [ ] **Step 4: Add the thin Vesta adapter**

Create `v-pull-docker-project-image ACTOR USER PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION IMAGE` using the normal Vesta command header and validation flow. Require `ACTOR == USER`, `standard`, exact preview authority and revision, and emit only bounded redacted image evidence JSON.

- [ ] **Step 5: Add broker dispatch**

Add:

```bash
image-pull)
    require_count 6 6 "$@" || exit 1
    # Validate project, preview/digests/revision, immutable reference, and standard authority.
    run_vesta_user_command v-pull-docker-project-image "$actor" "$actor" "$@"
    ;;
```

Do not add image load, image delete, build, raw pull options, owner/profile arguments, or Docker socket access.

- [ ] **Step 6: Correct standard image authority**

In `vx_compose_resolve_images_to_file`, for `standard` require:

```text
immutable submitted reference + matching owner image record
OR
matching current local-image approval for owner/reference/id/platform/standard-version
```

Do not treat a non-empty Docker `RepoDigests` array by itself as proof of registry delivery. A registry digest requires matching secure pull provenance; otherwise require local-image approval. Permit accepted-revision compatibility only for the identical owner/project/service/reference/image-ID/digest/platform tuple, with the existing exact five-field legacy validator and migration authority; never use it for add/change candidates or create provenance from it.

- [ ] **Step 7: Run focused tests and syntax validation**

Run:

```bash
bash -n bin/v-pull-docker-project-image bin/v-run-user-docker-command func/vx/compose/images.sh
bash test/compose/test-tenant-image-pull.sh
bash test/compose/test-images.sh
bash test/compose/test-image-approval.sh
bash test/compose/test-shell-access.sh
bash test/compose/test-shell-access-root-integration.sh
bash test/compose/test-cli-surface.sh
git diff --check
```

Expected: all pass. Do not run broad ShellCheck or the unrestricted production gate on constrained hosts.

- [ ] **Step 8: Commit the Vesta milestone**

```bash
git add bin/v-pull-docker-project-image bin/v-run-user-docker-command \
  func/vx/compose/images.sh test/compose .docs/contracts \
  docs/container-orchestration.md DOCKER_ORCHESTRATION_DEPLOYMENT.md
git commit -m "feat(compose): allow bounded tenant image pulls"
```

### Task 4: Independently review the security milestone

- [ ] **Step 1: Run a fresh specification review**

Review owner derivation, fixed standard profile, immutable digest parsing, pre-pull size admission, registry locking, secret redaction, local approval enforcement, legacy profile compatibility, broker namespace isolation, and absence of raw Docker/build/delete access.

- [ ] **Step 2: Fix only security/specification blockers**

Rerun the affected focused tests and commit coherent corrections without broad refactoring.

### Task 5: Roll out and accept development

**Hosts:**
- Primary development: `operator@192.0.2.10`
- Staging reference: `operator@192.0.2.20`

- [ ] **Step 1: Deploy the exact Vesta commit control plane**

Use an immutable archive, release lock, protected exact-file rollback backup, no `--delete`, no container/service restart, targeted syntax/config checks, and before/after container/firewall/route/tenant digests.

- [ ] **Step 2: Onboard development `legacyadmin`**

Create or select a package with positive standard-profile quotas matching one project/service, 1 CPU, 1024 MiB, 256 PIDs, one loopback port, three secrets, and one volume. Change the user package through Vesta so `DOCKER_PROJECTS` is persisted, reconcile `vesta-compose-users`, and remove `legacyadmin` from the raw `docker` group only after the managed cutover is ready.

- [ ] **Step 3: Build the Legacy workload candidate off-host**

On `builder@192.0.2.30:/home/builder/legacy-admin-app`, build from a remotely recoverable commit using the repository-owned Docker and workload builders. Validate the exact focused deployment tests and record image ID and artifact checksums without exposing secrets.

- [ ] **Step 4: Perform one-time development migration**

Use the root/admin workload-bundle install path once to establish three managed secrets and the generic `standard` project. Preserve a rollback record for the unmanaged `public_html` Compose container, stop it only at the final loopback-port cutover, require the Vesta-managed replacement healthy/readiness-pass, and restore the old container immediately if acceptance fails.

- [ ] **Step 5: Prove tenant operations**

From a fresh `legacyadmin` SSH identity require:

```bash
v-docker projects json
v-docker health legacy-admin-app json
v-docker drift legacy-admin-app json
```

Require raw `docker info` and direct `sudo v-*` denial. If an approved registry is available, create the exact preview, pull its fresh immutable digest through the preview-bound `v-docker image-pull`, and apply the same evidence; otherwise retain the focused immutable-pull tests and document registry provisioning as the only external prerequisite.

### Task 6: Synchronize Legacy workload-owned deployment knowledge

**Remote repository:** `builder@192.0.2.30:/home/builder/legacy-admin-app`

**Files:**
- Modify: `.vx/skills/legacy-admin-app-deploy/SKILL.md`
- Modify: `.vx/skills/legacy-admin-app-production-operations/SKILL.md`
- Modify: `@Docs/@TechnicalDocs/legacy-admin-app/deployment.md`
- Modify: `README.md`
- Create or modify as the Legacy workload maintainer chooses: repository-owned deployment script and focused tests

- [ ] **Step 1: Replace the obsolete local-archive default**

Make the normal release lane:

```text
build/test off-host -> push immutable registry digest ->
ssh legacyadmin preview -> preview-bound image-pull -> reviewed apply -> health/drift
```

Keep archive load/approval/workload import documented only as one-time migration, offline recovery, or operator fallback.

- [ ] **Step 2: Give the maintainer an exact script contract**

Require script inputs `environment`, SSH target, owner, project, immutable image reference, Compose file, and add/change mode. Require protected preview JSON, exact returned owner/profile/mode/digests/revision validation, explicit apply confirmation, no secret argv/environment logging, no raw Docker, and production authorization separate from development success.

- [ ] **Step 3: Explain profile and host state**

State that new Legacy workload releases are generic `standard` v2. The legacy production revision remains `legacy-admin-app` until an authorized migration; tenant scripts must fail closed rather than trying to mutate that profile.

- [ ] **Step 4: Commit and push submodule then parent**

Commit/push `@Docs` first, commit its gitlink plus root docs/skills/scripts next, run the repository-required focused validations and hooks, then push `development` without bypass flags.

### Task 7: Prepare production without interruption

**Host:** `operator@production.example.com`

- [ ] **Step 1: Deploy only the accepted Vesta control-plane commit**

Retain a protected rollback backup and prove the revision-4 `legacyadmin/legacy-admin-app` container ID, image, health, restart count, Docker PID, routes, firewall structure, quota authority, mount guard, and stopped external rollback container remain unchanged.

- [ ] **Step 2: Onboard the `legacyadmin` account without workload mutation**

Persist the approved Docker package quota, change the Unix/Vesta shell to Bash only if SSH access is intended and the account files agree, reconcile `vesta-compose-users`, ensure no Docker-group membership, and prove `v-docker projects` works. The broker must continue denying the current privileged `legacy-admin-app` project.

- [ ] **Step 3: Do not migrate the production workload**

Because uninterrupted active-client service is required, leave revision 4, its profile, container, port, routes, secrets, volumes, and rollback authority unchanged. Record that tenant production deployment begins only after a separately authorized standard-profile migration window with tested rollback.

### Task 8: Final closeout

- [ ] **Step 1: Run affected-system gates**

Use focused Compose tests plus `test/compose/run-production-readiness-limited.sh` only where required and safe. Do not run broad ShellCheck or an unrestricted full gate on constrained hosts.

- [ ] **Step 2: Run final specification and code-quality reviews**

Review the complete Vesta change, Legacy workload documentation/script contract, development evidence, production no-mutation evidence, and rollback material.

- [ ] **Step 3: Push Vesta and report the maintainer response**

Push the clean Vesta branch and provide a concise response the user can paste into the Legacy workload thread containing the exact supported pipeline, development host readiness, production migration boundary, and commands the Legacy workload maintainer should implement.
