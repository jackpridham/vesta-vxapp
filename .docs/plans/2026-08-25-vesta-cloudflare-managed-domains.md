# Vesta-Owned Cloudflare Managed Domains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `$milestone-driven-implementation`. This is one integrated product milestone so implementation can run continuously and the user-requested single combined audit happens only after the complete feature is deployed without credentials.

**Goal:** Make every website created through the Vesta product panel or authenticated API receive an immutable Vesta-generated `s-<10 lowercase hex>.<configured-zone>` primary hostname, reconcile its exact Cloudflare A record, retain custom domains as aliases, automatically install a certificate valid for the primary and aliases under Cloudflare Full (strict), and delete the owned record and certificate with the website.

**Architecture:** Keep upstream myVesta restore/import commands compatible and put provider authority in `func/vx/cloudflare/` plus thin `v-*` adapters. A root-owned atomic configuration stores the scoped token, zone ID, account email, and API-derived zone name; a separate `VX_MANAGED_DNS_PROVIDER` setting selects Cloudflare without misrepresenting the installed BIND service in `DNS_SYSTEM`. Per-domain root-owned metadata records the exact Cloudflare record, active Origin CA certificate, and any pending revocations used for bounded cleanup. Vesta generates each private key and CSR locally, asks Cloudflare only to sign the exact Vesta primary/alias SAN set, installs it through guarded native Vesta SSL commands, and restores the prior served certificate transactionally if rotation fails.

**Tech Stack:** Bash, curl, jq, Vesta state files, PHP panel pages/templates, deterministic shell/PHP tests.

---

## Locked scope

- Vesta alone generates the ten-hex label. No create command or web request accepts a generated label or technical hostname.
- `v-add-web-domain` remains compatible for root-owned restore/migration/upstream internals. The panel and authenticated Vesta API route product creation through `v-add-vx-managed-web-domain`, whose signature has no `DOMAIN` argument and ignores any caller-supplied primary-domain field. Authenticated API creation fails before native mutation unless the provider is exactly `cloudflare-managed`; it never falls through to caller-owned primary-domain creation.
- Cloudflare automation manages only one A record in one configured zone. TTL is Cloudflare Auto (`1`) and proxying is enabled.
- The web domain's Vesta IP/NAT state supplies the A-record target; callers cannot supply provider address, zone, record type, TTL, proxy policy, token, or record ID.
- Custom domains are Vesta aliases. The DNS-page action attaches an already-configured external domain as an alias and does not alter that external domain's DNS. Before attachment, Vesta requires a token-accessible Cloudflare zone, an exact proxied A record to the selected Vesta ingress or proxied CNAME to the technical hostname, active edge-certificate coverage, and Full (strict) readback.
- Managed create issues one 5475-day Cloudflare Origin CA RSA certificate containing the generated hostname and complete current alias set. Alias add/remove rotates that certificate automatically; callers cannot supply hostnames, certificate material, or a certificate ID.
- Configured and alias zones must be accessible to the token for the required zone, DNS, settings, and certificate operations. Configuration enforces Full (strict) with readback, and certificate or alias-preflight failure rolls native state back instead of publishing a broken site.
- `DNS_SYSTEM` continues to identify the installed local DNS service. `VX_MANAGED_DNS_PROVIDER=cloudflare-managed` is the Vortex provider authority shown as “Cloudflare managed” in Server → Configure → DNS.
- Token, zone ID, account email, ingress address, record ID, provider response, and authorization headers never appear in argv, environment, UI, logs, history, or command output.
- Configuration and mutations are serialized with a provider lock. Configuration and record metadata are root-owned, non-symlink, mode `0600`; their parent directories are mode `0700`.
- Website deletion first verifies and revokes the exact active and pending owned Origin CA certificate IDs and deletes the exact owned Cloudflare record, then removes metadata and continues the normal Vesta deletion. Custom-alias DNS is never deleted. Bulk/user deletion stops if a protected child cannot be cleaned up.
- Native alias and website-delete paths treat either Cloudflare authority path as protected. Missing, partial, malformed, symlinked, mismatched-zone, or otherwise degraded record/certificate metadata fails closed before native mutation; coordinated cleanup retains the complete exact authority needed for a safe retry until both owned provider objects are confirmed absent.
- Managed IP changes reconcile the exact Cloudflare A record and compensate the local Vesta change if provider convergence fails.
- Manual SSL, certificate, and Let's Encrypt mutation surfaces fail closed for managed or degraded sites; only the narrowly scoped internal Origin CA capability may install or restore their certificate material.
- Changing the configured primary zone is rejected while managed record or certificate metadata exists; same-zone token rotation remains supported.
- Live Cloudflare acceptance reuses the already-protected `vx cf` configuration through Vesta's mode-`0600` config-file input; credentials are never copied into Git, argv, logs, or acceptance output.

## Files and responsibilities

- Create `func/vx/cloudflare/main.sh`: exact config parsing, secret-safe curl transport, API error typing, provider lock, status, reconcile, cleanup, generator, and metadata authority.
- Create `bin/v-configure-vx-cloudflare`: silent/config-file credential input and validation-before-atomic-write.
- Create `bin/v-list-vx-cloudflare-status`: value-free human/JSON health.
- Create `bin/v-change-vx-dns-provider`: allow only `local` and `cloudflare-managed`.
- Create `bin/v-add-vx-managed-web-domain`: generate internally, call native web creation, reconcile, and return only the generated hostname.
- Create `bin/v-reconcile-vx-cloudflare-web-domain`: bounded `USER DOMAIN [FORMAT]` compatibility adapter.
- Create `bin/v-delete-vx-cloudflare-web-domain`: exact owned-record cleanup adapter.
- Create `bin/v-add-vx-cloudflare-web-alias`: attach an already configured custom domain as a Vesta alias.
- Create `bin/v-list-vx-cloudflare-web-domain-status`: expose only the bounded `managed`, `degraded`, or `unmanaged` lifecycle state used by panel guards.
- Create `bin/v-reconcile-vx-cloudflare-origin-ssl` and `bin/v-delete-vx-cloudflare-origin-ssl`: issue/install the exact Vesta-derived SAN certificate and revoke its exact stored ID.
- Create `func/vx/cloudflare/origin-ca-rsa.pem` and `func/vx/cloudflare/web-hooks.sh`: ship the official Cloudflare Origin CA RSA root and keep native alias changes thin while rotating or rolling back certificates.
- Modify `bin/v-add-web-domain-alias` and `bin/v-delete-web-domain-alias`: invoke the VX certificate hook only for managed sites and compensate alias state when rotation fails.
- Modify `bin/v-change-web-domain-ip`: reconcile the exact managed A record and restore local/provider state on failure.
- Modify native SSL and Let's Encrypt adapters: reject external mutation for managed or degraded domains while accepting only the internal Vortex Origin CA installation capability.
- Modify `bin/v-delete-web-domains`: stop bulk/user deletion when any protected child cleanup fails.
- Modify `bin/v-list-sys-config`: expose only the bounded nonsecret managed-provider enum to the existing server form.
- Modify `bin/v-delete-web-domain`: thin managed-record cleanup hook before destructive local deletion.
- Modify `bin/v-change-web-domain-name`: reject rename of Vesta-managed technical hostnames.
- Modify `web/add/web/index.php` and `web/templates/admin/add_web.html`: remove caller primary-domain input, make custom domains the visible alias input, and consume the generated hostname returned by the Vortex command.
- Modify `web/api/index.php`: route authenticated product creation through the Vesta allocator while preserving low-level restore/import compatibility.
- Modify `web/edit/web/index.php` and the admin/user edit templates: hide and reject manual certificate or Let's Encrypt changes for managed/degraded domains.
- Create `web/add/vx-cloudflare-domain/index.php` and `web/templates/admin/add_vx_cloudflare_domain.html`: admin-only CSRF-protected external-domain alias form.
- Modify `web/templates/admin/list_dns.html`: add the requested adjacent Cloudflare-domain button.
- Modify `web/edit/server/index.php` and `web/templates/admin/edit_server.html`: provider selector and sanitized configuration state/instructions.
- Create `test/cloudflare/test-cloudflare-managed-domains.sh`: stubbed provider and lifecycle acceptance.
- Create `test/test_cloudflare_web_ui.php`: source-contract coverage for CSRF, escaping, ownership, generated-domain input removal, DNS button, and provider selector.
- Create `.docs/user-guides/vesta-cloudflare-managed-dns.md`: operator configuration, rotation, status, recovery, and credential requirements.
- Modify `.docs/README.md`: index the guide and this plan.

## Integrated implementation milestone

### Task 1: Provider authority and exact record lifecycle

- [x] **Step 1: Add a failing provider-stub test**

The test creates a synthetic Vesta root and fixed curl stub. It asserts `not_configured`, atomic mode-`0600` configuration, value-free output, create/no-op/update/readback, duplicate rejection, malformed/401/403/429/timeout failures, and exact idempotent deletion. It also inspects captured process arguments and environment to prove protected values are absent.

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected before implementation: `FAIL: missing Cloudflare helper or command`.

- [x] **Step 2: Implement the minimal provider helper and adapters**

Public contracts:

```text
v-configure-vx-cloudflare [--config-file ROOT_ONLY_FILE]
v-list-vx-cloudflare-status [json]
v-change-vx-dns-provider local|cloudflare-managed
v-reconcile-vx-cloudflare-web-domain USER DOMAIN [json]
v-delete-vx-cloudflare-web-domain USER DOMAIN [json]
```

Provider transport uses a temporary mode-`0600` curl config containing URL, method, headers, body-file path, output path, and timeouts. Runtime argv is only `/usr/bin/curl --config <temporary-path>` under an empty environment. JSON responses remain in bounded temporary files and only stable codes such as `ready`, `not_configured`, `unauthorized`, `rate_limited`, `timeout`, `malformed_response`, `ambiguous_record`, `created`, `unchanged`, `updated`, and `deleted` leave the helper.

- [x] **Step 3: Run the focused provider test**

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected: all provider and lifecycle assertions pass without a network request.

### Task 2: Vesta-owned website identity and cleanup

- [x] **Step 1: Extend the failing lifecycle fixture**

Assert two generated labels match `^s-[a-f0-9]{10}$`, differ, contain no user/alias material, and are never accepted as input. Assert aliases are passed to native web creation, collisions retry, a successful create has exact record metadata, rename is rejected, and native deletion removes the exact record before the local domain.

- [x] **Step 2: Implement the managed creation surface and thin hooks**

Public create contract:

```text
v-add-vx-managed-web-domain USER [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS] [native proxy long options]
```

It reads the configured zone name, makes five random bytes with `/dev/urandom`, encodes ten lowercase hex characters, performs bounded Vesta/provider collision checks, calls `v-add-web-domain`, reconciles/readbacks Cloudflare, and emits only the resulting technical hostname. The generic native create contract remains unchanged.

- [x] **Step 3: Re-run the focused lifecycle test**

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected: generated identity, aliases, immutable rename, and create/delete order pass.

### Task 3: Panel delivery

- [x] **Step 1: Add a failing PHP source-contract test**

Assertions require the web controller to call `v-add-vx-managed-web-domain` without `v_domain`, require the template to have no editable/posted primary-domain input, require the alias form to preserve CSRF and `escapeshellarg`, require admin authorization, require the DNS toolbar link, and require the server provider selector to call only `v-change-vx-dns-provider`.

Run: `php test/test_cloudflare_web_ui.php`

Expected before implementation: `FAIL` on the missing Vortex panel surfaces.

- [x] **Step 2: Implement the thin PHP/template integration**

The add-web page treats custom domains as aliases, obtains the generated hostname from the successful command response, and then uses that server result for existing FTP/SSL/stats flows. The new DNS toolbar form attaches an already-configured custom hostname to a selected owned web domain. Server configuration displays local versus Cloudflare-managed provider mode and only a configured/not-configured credential status.

- [x] **Step 3: Run focused UI tests and syntax checks**

Run:

```bash
php test/test_cloudflare_web_ui.php
php -l web/add/web/index.php
php -l web/add/vx-cloudflare-domain/index.php
php -l web/edit/server/index.php
```

Expected: tests pass and every file reports `No syntax errors detected`.

### Task 4: Documentation, issue, deployment checkpoint, and the single audit

- [x] **Step 1: Document the operator workflow and update issue #5**

The guide records the least-privilege token (Zone Read, Zone Settings Read/Write, DNS Read/Edit, and SSL and Certificates Read/Edit for the configured and alias zones), secure interactive/config-file setup, provider selection, health, create/delete semantics, recovery, and rotation. Issue #5 receives this locked implementation plan and explicitly notes that downstream consumer issue #145 must consume the Vesta allocator before claiming Vesta-owned API Site generation.

- [x] **Step 2: Run the one integrated validation/audit loop**

Run exactly once after implementation:

```bash
bash -n func/vx/cloudflare/main.sh func/vx/cloudflare/web-hooks.sh bin/v-configure-vx-cloudflare bin/v-list-vx-cloudflare-status bin/v-change-vx-dns-provider bin/v-add-vx-managed-web-domain bin/v-reconcile-vx-cloudflare-web-domain bin/v-delete-vx-cloudflare-web-domain bin/v-add-vx-cloudflare-web-alias bin/v-list-vx-cloudflare-web-domain-status bin/v-reconcile-vx-cloudflare-origin-ssl bin/v-delete-vx-cloudflare-origin-ssl bin/v-add-web-domain-alias bin/v-delete-web-domain-alias bin/v-add-letsencrypt-domain bin/v-delete-letsencrypt-domain bin/v-add-web-domain-ssl bin/v-change-web-domain-sslcert bin/v-delete-web-domain-ssl bin/v-change-web-domain-ip bin/v-delete-web-domains bin/v-delete-web-domain bin/v-change-web-domain-name
bash test/cloudflare/test-cloudflare-managed-domains.sh
bash test/cloudflare/test-cloudflare-native-lifecycle.sh
php test/test_cloudflare_web_ui.php
php test/test_web_proxy_form.php
bash test/test_web_domain_proxy.sh
php -l web/add/web/index.php
php -l web/add/vx-cloudflare-domain/index.php
php -l web/edit/server/index.php
php -l web/edit/web/index.php
php -l web/api/index.php
git diff --check
```

One independent reviewer checks the complete diff for specification, secret safety, exact deletion authority, and regressions. Any numbered blocker is fixed once and rechecked only against that blocker.

- [x] **Step 3: Commit and deploy the implementation**

The coherent feature was committed and installed as root-owned files on the approved development target. Exact deployed hashes and modes, PHP/Bash syntax, panel routes, service health, and sanitized provider status were verified. No production host was changed.

- [x] **Step 4: Configure and run protected live acceptance**

Protected credentials were transferred through the existing `vx cf` configuration surface into a temporary root-owned mode-`0600` input, then removed. Development acceptance proved provider/API readback, exact proxied records, generated and alias HTTPS through Full (strict), migration apply/rollback, normal deletion, and exact provider cleanup without recording protected values.

## Acceptance checklist

- [x] Every panel-created site has a Vesta-generated immutable `s-<10 hex>.<zone>` primary hostname.
- [x] No caller can provide the generated label/hostname to the managed create surface.
- [x] Custom domains are aliases; the DNS-area action attaches an already configured external domain without mutating its DNS.
- [x] Managed create and alias mutation automatically install a certificate whose SANs exactly cover the generated hostname and all current aliases, so Cloudflare Full (strict) succeeds.
- [x] Private keys remain on Vesta; superseded/deleted exact Origin CA certificate IDs are revoked.
- [x] Technical A-record create/no-op/update/readback and exact idempotent deletion work.
- [x] Website deletion cannot leave a known owned record behind or delete any broader record set.
- [x] Provider selection is visible in Server → Configure → DNS while installed `DNS_SYSTEM` remains intact.
- [x] Credentials and provider values never leak through argv, environment, output, logs, UI, test evidence, or Git.
- [x] Stubbed validation, syntax checks, one combined audit, one targeted remediation, commit, protected configuration, and target acceptance completed without exposing credentials.

Development acceptance produced only bounded evidence: three disposable sites,
two aliases, six HTTPS checks, two migrations, two deletions, and exact provider
cleanup passed. All five Cloudflare suites, focused panel/proxy regressions, the
limited production-readiness launcher, syntax checks, and diff checks passed on
the owner repository. This is development evidence for `vesta-vxapp`; no
production deployment occurred.

## Explicit migration milestone for existing websites

This migration is deliberately separate from package installation and the
normal website-create path. It lives under
`install/migrations/cloudflare-managed-web-domains/` and is invoked manually
only after the configured provider reports exactly `ready`.

- [x] `prepare.sh PLAN [--user USER] [--json]` creates a protected immutable
  inventory and exact rollback snapshots without changing Vesta or provider
  state. The default scope includes every authoritative web-domain row,
  including suspended users and domains.
- [x] `apply.sh PLAN [--json]` binds to that exact inventory, allocates all
  technical names internally, migrates each website in place, creates only its
  technical A record, installs and verifies its exact Origin CA SAN set, and
  records the protected downstream issue #140 mapping.
- [x] `rollback.sh PLAN [--json]` reverses only transaction-owned authority and
  restores exact pre-migration website state. Failed verification remains in
  durable root-only `recovery_required` state.
- [x] A protected plan-bound rollback-admission artifact fingerprints the whole
  scoped authoritative `web.conf` and rendered web tree at each stable state.
  Apply and rollback reject unrelated row, template/proxy, or rendered-tree
  drift before provider or native mutation instead of overwriting it.
- [x] A focused migration fixture proves dry-run non-mutation, suspended and
  multi-alias/proxy preservation, unique Vesta-owned allocation, all failure
  compensation boundaries, exact cleanup authority, idempotency, deletion
  after migration, drift rejection, and secret-safe output/process surfaces.
- [x] The complete migration and existing Cloudflare/native/proxy regression
  suites pass one combined review and at most one targeted remediation before
  the implementation is committed. No live `apply.sh` occurs without a
  separately confirmed online host, configured credentials, and approved plan.

## Cross-repository dependency

- Owner: this Vesta repository owns hostname allocation, Cloudflare configuration, record lifecycle, panel creation, and external-domain alias attachment.
- Consumer: downstream issue #139 must call the Vesta allocator/reconcile contract without receiving Cloudflare credentials or choosing the generated hostname.
- Contract correction: downstream issue #145 currently allocates `s-<32 hex>` inside the consumer API. It must be revised before API-created Sites can claim the Vesta-owned `s-<10 hex>` contract requested here; this implementation does not silently mutate that separate repository.
- The owner implementation has passed protected development acceptance only.
  Downstream API issues #139, #140, #142, #145, and #227 remain separate
  consumer/release dependencies; none is satisfied by this repository's dev
  deployment, and no production deployment is claimed.

## Non-goals

- General-purpose Cloudflare DNS CRUD, record backup, cache purge, or persisting/managing custom-alias zones beyond bounded validation and strict-mode enforcement.
- Copying the broad `vortex-scripts` command surface or its argv-visible authorization header pattern.
- Mutating DNS for custom aliases that the operator says are already configured.
- Replacing BIND/named service lifecycle or changing restore/migration compatibility commands.
- Treating provider API success as public propagation, certificate readiness, proxy health, or production authorization.
