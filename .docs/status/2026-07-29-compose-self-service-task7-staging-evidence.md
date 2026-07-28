# Task 7 staging evidence — 2026-07-29

Status: **PASSED**

Latest disposition: the final `472b19f6` retry passed the full committed
overlay, focused host gates, lifecycle, authenticated browser acceptance, and
exact isolation checks. The overlay remains installed on staging, its upload
was removed, and the fresh rollback archive is retained.

- Target: `debian@192.168.100.100` through
  `gizmo@192.168.100.16`
- Implementation: `472b19f66acc0a5c92ff103363aa4326019eae72`
- Overlay paths: 48 committed regular files
- Overlay archive SHA-256:
  `719af35e234e38334017a85b0038009ab2308d1982218ca8c47c1cec5e47fc4b`
- Final rollback archive:
  `/var/backups/vesta/vx-self-service-472b19f66acc0a5c92ff103363aa4326019eae72`
- Preserved failed-Step-3 rollback evidence:
  `/var/backups/vesta/vx-self-service-77de612ab73286e60a5c38370de82b2c9d6220d5.failed-step3-1785253945`

## Results

- Read-only preflight passed at `2026-07-29T01:48:26+10:00`.
  Hostname, Vesta root, Docker `26.1.5+dfsg1`, Docker Compose
  `2.26.1-4`, `pwcp9.pkg`, scratch collision checks, port `18081`, and
  nginx passed.
- The sorted baseline contained one unrelated container.
- The exact overlay archive type, path-list equality, isolated extraction,
  archive checksum, and all 38 content hashes passed.
- The runbook required two authorized operational corrections:
  `LC_ALL=C` for the sorted `comm` set operation, and root-side expansion for
  rollback metadata chmod inside the root-only rollback directory.
- The corrected install completed and all 38 installed hashes passed. Its
  rollback archive contains 28 prior files and 10 allowlisted new paths.
- The host gate stopped during the required ShellCheck invocation. The
  process remained in uninterruptible disk sleep after the additional bounded
  180-second observation window. `/proc` showed waits in
  `folio_wait_bit_common` and `rq_qos_wait`; physical reads reached about
  8.1 GB for about 1.15 MB of logical input.
- The non-D parent command sequence was terminated so it could not advance
  after the failed gate. The D-state ShellCheck process was not signalled.
- The exact Task 7 rollback passed: rollback archive checksum, all old hashes,
  all old modes/owners, required Bash syntax, PHP lint, nginx, and scratch
  absence.
- Final cleanup removed only the exact remote upload. The scratch owner, user
  data, labeled containers, networks, volumes, previews, and listener on
  `18081` are absent. Nginx passes.
- The final sorted unrelated-container list exactly matches the baseline.
- The protected Playwright environment was absent. Browser acceptance was not
  run, both because the preceding host gate failed and credentials were
  unavailable.
- Production was not accessed. No firewall, prune, broad cleanup, or
  `rsync --delete` action was used.

## Acceptance

Task 7 must not be marked successful. The overlay is rolled back and staging
is clean, but the required host gate and subsequent lifecycle/browser gates
did not complete. Resolve the staging host I/O condition and provide the
protected browser environment before retrying.

## Resume audit at 02:10 AEST

- A fresh read-only audit found the prior ShellCheck process still present in
  uninterruptible disk sleep at `folio_wait_bit_common`.
- Its physical-read counter had increased to approximately 10.1 GB.
- Root filesystem capacity was 19% used and inode usage was 2%. The restricted
  kernel error query returned no messages. Docker, Compose, and nginx remained
  responsive.
- Simple bounded reads passed for all 28 currently installed overlay targets;
  the 10 additive overlay paths remained absent after rollback.
- Fresh owner, data, label, and port collision checks passed. The sorted
  container baseline remained identical.
- No redeployment was attempted because the required condition that the prior
  D-state process be gone was not satisfied.

## Resource-safe retry at 02:14 AEST

- After the stranded process was externally cleared, fresh preflight passed
  with about 672 MiB available memory. The prior current rollback archive was
  preserved as
  `/var/backups/vesta/vx-self-service-77de612ab73286e60a5c38370de82b2c9d6220d5.failed-step4-1785255239`.
- The exact overlay was installed again and all content hashes passed.
- The controller-authorized sequential ShellCheck gate passed the first ten
  Compose helper files. Per-file peak process-tree RSS ranged from about
  18 MiB to 153 MiB.
- `bin/v-plan-docker-project-source` exceeded its individual 120-second
  timeout and reached approximately 909 MiB peak process-tree RSS. The
  remaining ShellCheck files and all later Task 7 gates were not run.
- The current exact rollback passed again: archive checksum, old hashes,
  old ownership/modes, Bash syntax, PHP lint, nginx, and scratch absence.
- The exact remote upload was removed. Scratch owner/data, labeled Docker
  resources, listener, and unrelated-container baseline all remained clean.
  All three rollback evidence roots were retained.
- The authoritative protected Playwright environment remained absent.
  `.env.playwright.local` was not read because it is mode 0644.

## Decomposed-gate retry at 02:20 AEST

- The exact combined local `shellcheck -x -S warning` gate passed.
- The controller-approved remote decomposition passed all ten helper checks
  with `-x` and all four command-adapter checks without `-x`. Peak helper RSS
  was about 141 MiB; adapter checks peaked around 18 MiB.
- All exact backend, web, PHP, Compose fixture, and nginx gates passed.
- The exact lifecycle script then failed before scratch-user creation while
  sourcing `func/main.sh`: line 10 referenced unset variable `user` under the
  script's `set -u`.
- No lifecycle workload was created. The current exact rollback and final
  container-baseline comparison passed, and the exact upload was removed.
- The authoritative protected browser environment remained absent, and the
  insecure local dotenv was not used.

## Corrected-lifecycle retry at 02:24 AEST

- The identical installed hashes and focused host tests passed; the accepted
  decomposed ShellCheck evidence remained applicable to the same bytes.
- With the authorized Vesta source/nounset correction, lifecycle reached the
  revision-one runtime apply.
- Docker created network `vx-vxsscp12-selfservice_default`, but runtime
  validation looked for `vx_vxsscp12_selfservice_default`. Apply failed with
  `managed project network does not exist`.
- The first exact rollback attempt exposed another runbook environment defect:
  Step 8 did not export `VESTA` before invoking scoped Vesta commands. The
  controller authorized an immediate corrected rollback.
- The corrected rollback exported `VESTA`, removed only
  `vxsscp12/selfservice` and exact owner-labeled runtime, deleted the scratch
  user, restored the archive, and passed old hashes/modes, Bash, PHP, nginx,
  and Docker isolation checks.
- The exact upload was removed and the unrelated-container baseline matched.
  Browser credentials remained absent.

## Network-fix retry at 02:37 AEST

- Retried committed implementation
  `1a8fd363da4b6597320da4fb28d52d3093663c1f`.
- The 41-path archive SHA-256 was
  `a3eba48308608aa719593ee5aa7a4bdaa2c9927c50d567c5dcb46555afced1cd`.
- Installed hashes, local combined ShellCheck, decomposed remote ShellCheck,
  backend/web/PHP, all Compose fixtures, network/canonicalization tests, and
  nginx passed.
- The lifecycle stopped at scratch-user creation with
  `Error: user vxsscp12 exists`, although fresh preflight had proven both the
  system user and Vesta data path absent. Failure-state inspection found no
  system user but a partial Vesta user-data path.
- Corrected scoped rollback removed the partial owner/project state, restored
  the exact archive, and passed hashes, modes, Bash, PHP, nginx, Docker
  isolation, port, and unrelated-container-baseline checks.
- The exact upload was removed. The protected browser environment remained
  absent.

## User-add diagnosis at 02:41 AEST

- No concurrent or stranded `v-add-user`, lifecycle, Task 7, or prior SSH
  process was found. Vesta recorded exactly one later `v-add-user` attempt at
  `02:38:57`, returning error 4.
- The live Vesta user directory was still present without a system user.
  Its files are timestamped `02:24:27` through `02:24:39`, tying it to the
  earlier failed lifecycle.
- Root cause of the false collision/cleanup passes: the runbook expresses
  absence assertions as standalone `! test ...`, `! id ...`, and similar
  commands under `set -e`. Bash suppresses errexit for inverted commands, so
  a failed absence assertion did not stop the script; subsequent successful
  nginx or other checks made the overall SSH command succeed.
- Therefore the later `v-add-user` was not raced or invoked twice. It correctly
  rejected the orphan Vesta data left by the earlier rollback.
- Current state at diagnosis was not isolated:
  `/usr/local/vesta/data/users/vxsscp12` remained present, while the system
  user, labeled Docker resources, and port listener were absent.
- A deterministic retry must hold an exact root flock for the whole Task 7
  lifecycle and use explicit `if ...; then exit 1; fi` collision/isolation
  checks instead of relying on standalone `!` commands.

## Orphan recovery at 02:44 AEST

- Read-only enumeration found a valid Vesta user record and home, no passwd or
  group entry, no owner-labeled Docker resources, no port listener, and no
  owner previews.
- Five exact `vxsscp12` queue entries remained: four disk updates and one
  traffic update.
- Code inspection confirmed normal `v-delete-user` supports this partial
  state: it validates the Vesta record, removes scoped runtime and queue
  entries, tolerates missing passwd/group entries, and removes the exact home
  and Vesta data.
- Under root flock `/run/lock/vx-task7-vxsscp12.lock`, normal
  `v-delete-user vxsscp12` completed successfully.
- Explicit `if`-based checks proved the system account, Vesta data, home,
  owner-labeled containers/networks/volumes, port, previews, and queue
  references absent. Nginx passed and the unrelated container ID remained
  `ebfd7e90bada`.
- Queue mutation: the five exact scratch-owner queue lines were removed by the
  normal scoped Vesta deletion command. No fallback move was required.

## Locked retry after orphan recovery

- One root flock on `/run/lock/vx-task7-vxsscp12.lock` was held continuously
  across preflight, installation, gates, lifecycle, rollback, and cleanup.
- Explicit collision checks passed. The 41-path overlay at `1a8fd363` and all
  installed hashes, decomposed ShellCheck, focused tests, PHP, fixtures,
  network/canonicalization tests, and nginx passed.
- Lifecycle created a healthy container and the correctly named network, but
  failed revision-one convergence with
  `managed project network ownership labels do not match`.
- Scoped rollback restored all prior files and removed the exact owner/runtime.
  The strengthened explicit preview check found one retained scratch preview;
  it was removed only after ID, parent, non-symlink, root:0700, owner, and
  project validation.
- Final explicit checks passed for account, Vesta data, home, labeled
  containers/networks/volumes, port, previews, and queue references. The
  unrelated-container baseline matched exactly and nginx passed.
- The exact upload was removed before releasing the flock. The protected
  browser environment remained absent.

## Canonical-label fix retry

- Retried committed implementation
  `fbc66e5fbc00f4eb493b245e2a554949341e0fd4`.
- The 41-path archive SHA-256 was
  `d1e2af24a335d569e08339bd91ddfeb98be3aa9666491ca120ed7968bf69bb61`.
- One root Task 7 flock was held across preflight, installation, all gates,
  lifecycle, cleanup, and final baseline comparison.
- Installed hashes, decomposed ShellCheck, backend/web/PHP, fixtures,
  network/canonicalization tests, and nginx passed.
- The full lifecycle passed: healthy revision 1, healthy legacy revision 2,
  stale confirmation refusal, unhealthy-candidate rollback to healthy revision
  2, actor audit attribution, canary/path redaction, and retained-preview
  validation/removal.
- Exact project deletion with retained data and normal user deletion passed.
  Explicit checks proved account, Vesta data, home, labeled containers,
  networks, volumes, port, previews, and queue references absent.
- The exact upload was removed, nginx passed, and the unrelated-container
  baseline matched before the root flock was released.
- The protected `/run/user/.../vesta-vxapp-playwright.env` remained absent, so
  authenticated browser acceptance did not run. Task 7 therefore remains
  `NEEDS_CONTEXT` rather than successful.

## Authenticated browser retry at `ed015437`

- Retried exact committed implementation
  `ed01543705f77b779545903ca9c726886b19546a`.
- The additive overlay contained 43 committed regular paths and its archive
  SHA-256 was
  `f8908c9492d8d85b09adf2058349d4e8afa9f7204ebc718487f457f9d328b346`.
- The fresh rollback archive is retained at
  `/var/backups/vesta/vx-self-service-ed01543705f77b779545903ca9c726886b19546a`.
  The exact remote upload was removed after recording evidence.
- Explicit collision checks passed. The archive checksum, archive/path-list
  equality, isolated extraction, all 43 source hashes, and all 43 installed
  hashes passed.
- Exact combined local ShellCheck passed. Resource-safe remote ShellCheck
  decomposition passed for the ten helpers with `-x` and the four thin
  adapters without source traversal. Bash syntax, all six focused shell
  suites, three PHP lints, PHP helper tests, all seven Compose fixtures, and
  nginx passed.
- `fbc66e5f..ed015437` changes only the Playwright/env contract, PHP
  helper/test, and browser fixture files. No runtime Bash changed, so the
  already-passed exact `fbc66e5f` lifecycle remains applicable and was not
  repeated.
- The approved mode-0600 `.env.playwright.local` was used without printing or
  copying protected values. The explicit staging jump and disposable-runtime
  opt-in were supplied.
- Playwright completed with **3 passed and 3 failed**. Authentication setup,
  fail-closed/collision-resistant naming, and SSH jump/argv safety passed.
  The owner and stale workflows failed while reading confirmation fields with
  `TypeError: Class extends value #<Object> is not a constructor or null`.
  The unhealthy-update workflow reached its output watcher but timed out
  after 120 seconds because the textarea remained empty instead of reporting
  failure.
- Playwright's scoped project cleanup removed its projects and Docker
  resources. Three retained previews were independently tied to this run by
  exact timestamp and generated project name; they were removed only after
  validating the 32-hex ID, exact parent, non-symlink root:0700 directory,
  owner, and exact project metadata. Two older `pw-self-stage-*` previews were
  unrelated and were not touched.
- Final explicit checks proved the current `pw-self`, `pw-stale`, and
  `pw-rollback` projects, control/data state, labeled containers, networks,
  volumes, and previews absent. The older Task 7 `vxsscp12` account, data,
  home, labeled Docker resources, listener, and scratch state remain absent.
  Nginx passes and the unrelated-container baseline matches exactly.
- Production and firewall state were not accessed. No prune, broad cleanup,
  or ad hoc code patch was used.

Task 7 remains **BLOCKED** on the three authenticated browser failures. The
current overlay remains installed on staging and the fresh rollback archive
is retained.

## Final full-overlay retry at `86a73b70`

- Retried exact committed implementation
  `86a73b70107830afe54f5dded3b3b9ac22ddb83e`.
- The full additive `2885042b..86a73b70` overlay contained 48 committed
  regular paths. Deletions, symlinks, whitespace paths, and paths outside the
  approved Vesta/documentation areas plus the committed
  `.env.playwright.example` contract were rejected. The archive SHA-256 was
  `2848d1eb6aa66596fa0a4fe8ce8d516f97f1db680a54f6fba4a19ecd34e988b9`.
- A single root flock on `/run/lock/vx-task7-vxsscp12.lock` was held from
  collision preflight through install, host gates, browser execution,
  rollback, and cleanup. All collision and isolation assertions used explicit
  `if` failures rather than standalone inverted commands.
- Fresh preflight passed for the scratch account, Vesta data and home,
  owner-labeled containers, networks and volumes, port `18081`, previews,
  queue references, nginx, and the rollback-root collision. The unrelated
  container baseline was exactly `ebfd7e90bada`.
- Archive checksum, archive/path equality, isolated extraction, and all 48
  source and installed hashes passed. The fresh rollback archive is
  `/var/backups/vesta/vx-self-service-86a73b70107830afe54f5dded3b3b9ac22ddb83e`;
  it records 47 replaced files and one new file.
- Installation retained the accepted `LC_ALL=C` correction for `comm` and
  root-side `find ... -exec chmod` for rollback metadata. The full overlay
  added `test/js/`, so parent validation used canonical `realpath -m` after
  archive/path allowlisting instead of incorrectly requiring that new parent
  directory to pre-exist.
- Resource-safe staging ShellCheck passed sequentially with `-x` for all ten
  Compose helpers and as body-only checks for the four thin command adapters.
  The exact combined source-following invocation had already passed locally
  for the same committed bytes in the prior accepted evidence.
- Bash syntax, deployment-plan, immutable-preview, transaction, audit,
  web-job, web-UI, PHP lint/helper, all seven Compose fixture,
  canonicalization, network-policy, and nginx gates passed. The newly affected
  floating-dialog watcher test passed locally; staging has no Node binary.
- `fbc66e5f..86a73b70` contains no runtime Bash changes. The exact
  `fbc66e5f` healthy revision-one, healthy legacy revision-two, stale refusal,
  unhealthy rollback, audit attribution, redaction, retained-preview, and
  scoped cleanup lifecycle evidence therefore remains hash-applicable.
- The approved mode-0600 `.env.playwright.local` was used without printing or
  copying credentials. The exact staging jump, disposable-runtime opt-in, and
  `chromium-docker-user-authenticated` project were supplied.
- Authenticated Playwright did **not** pass 6/6. Setup, fail-closed and
  collision-resistant naming, and SSH jump/argv safety passed. The owner
  workflow then failed because the confirmation POST returned
  `The validated Compose preview expired`, and
  `#compose-spawn-output textarea` was never rendered. Server-side retained
  metadata showed the candidate was newly created with an expiry exactly 900
  seconds later, so this is a confirmation/session-contract failure rather
  than an actually expired preview. The remaining lifecycle browser cases did
  not establish passing evidence.
- Because browser acceptance failed, the exact file rollback was run. The
  rollback archive checksum, all 47 old hashes, modes and owners, Bash syntax,
  PHP lint, and nginx passed. The sole allowlisted new file
  `test/js/test-floating-div.js` was removed.
- Exact current `pw-self-*`, `pw-stale-*`, and `pw-rollback-*` control/data
  state, labeled containers, networks, volumes, previews, job/queue
  references, and the Task 7 `vxsscp12` account, Vesta data, home, labeled
  runtime, previews, queue references, and port were absent. Older unrelated
  `pw-self-stage-*`/`pw-self-repro-*` lock files were left untouched.
- The exact remote upload was removed, nginx passed, and the final unrelated
  container list exactly matched the baseline (`ebfd7e90bada`) before the
  root flock was released. Production, firewall state, global prune, and broad
  cleanup were not accessed.

Task 7 remains **BLOCKED** because authenticated browser acceptance is not
6/6. The `86a73b70` overlay is rolled back and staging is clean; the fresh
rollback archive is retained for closeout evidence.

## Successful final retry at `472b19f6`

- One root flock on `/run/lock/vx-task7-vxsscp12.lock` was held from the
  fresh collision preflight through archive installation, host gates,
  lifecycle, browser execution, scoped cleanup, and final baseline
  comparison.
- Preflight passed at `2026-07-29T09:29:46+10:00`. The scratch account,
  Vesta data and home, owner-labeled containers, networks and volumes, port
  `18081`, previews, queue references, and rollback-root namespace were
  absent. Docker was `26.1.5+dfsg1`, Compose was `2.26.1-4`, nginx passed,
  and the unrelated-container baseline was exactly `ebfd7e90bada`.
- The additive `2885042b..472b19f6` overlay contained 48 committed regular
  paths. Deleted paths, symlinks, whitespace paths, and paths outside the
  explicit Vesta/documentation plus `.env.playwright.example` allowlist were
  rejected. Its SHA-256 was
  `719af35e234e38334017a85b0038009ab2308d1982218ca8c47c1cec5e47fc4b`.
- Archive checksum, archive/path equality, isolated extraction, all source
  hashes, and all installed hashes passed. The first install backed up 47
  existing files and recorded one allowlisted new file.
- Local combined source-following ShellCheck passed. Resource-safe staging
  ShellCheck passed sequentially with `-x` for ten Compose helpers and
  without source traversal for four thin public adapters. Bash syntax, all
  six focused shell suites, PHP lint and helper tests, all seven Compose
  fixtures, the identical-byte local watcher harness, and nginx passed.
- The full current-byte lifecycle passed: healthy revision one, healthy
  revision two, stale-preview refusal, unhealthy-candidate rollback to
  healthy revision two, actor audit attribution, canary/source-path
  redaction, retained-preview validation, and exact retained-preview removal.
- The first authenticated browser invocation failed before application tests:
  authentication setup timed out on the initial `/login/` navigation with
  `net::ERR_ABORTED`. The exact overlay and lifecycle state were rolled back,
  all old hashes/modes/owners and nginx passed, the upload was removed, and
  the unrelated-container baseline matched. Three immediate independent
  HTTPS probes then returned HTTP 200 in approximately 0.07 seconds each.
- That failed-attempt rollback archive was preserved at
  `/var/backups/vesta/vx-self-service-472b19f66acc0a5c92ff103363aa4326019eae72.failed-auth-1785281740`.
  A fresh rollback root was created and all 48 committed overlay hashes were
  installed and verified again before the browser retry.
- The protected mode-0600 `.env.playwright.local` was used without printing
  or copying credentials. With the explicit staging ProxyJump,
  disposable-runtime opt-in, and
  `chromium-docker-user-authenticated` project, the focused authenticated
  workflow passed **6/6 in 1.2 minutes**. It covered authentication, helper
  failure modes and SSH argument safety, owner preview/create/update and
  authority refusal, stale confirmation refusal, and unhealthy-update
  rollback.
- Browser fixture cleanup removed its project and Docker state. Two
  intentionally retained stale/rollback previews were removed only after
  validating their 32-hex IDs, exact parent, non-symlink root-owned mode-0700
  directories, `dockere2e` ownership metadata, exact generated project
  prefixes, absent project records, and absent labeled containers.
- Final explicit checks proved the Task 7 account, Vesta data, home,
  owner-labeled containers, networks and volumes, port, previews and queue
  references absent. Current `pw-self-*`, `pw-stale-*`, and `pw-rollback-*`
  project records, labeled runtime, and previews were absent. Nginx passed,
  the exact upload was removed, and the final sorted container list matched
  the baseline (`ebfd7e90bada`) before the root flock was released.
- The passing overlay remains installed. The fresh rollback archive is
  `/var/backups/vesta/vx-self-service-472b19f66acc0a5c92ff103363aa4326019eae72`.
  Production and firewall state were not accessed. No prune, broad cleanup,
  or `rsync --delete` action was used.

Task 7 acceptance is **PASSED**.
