# Vesta-Owned Cloudflare Managed Domains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `$milestone-driven-implementation`. This is one integrated product milestone so implementation can run continuously and the user-requested single combined audit happens only after the complete feature is deployed without credentials.

**Goal:** Make every website created through the Vesta panel receive an immutable Vesta-generated `s-<10 lowercase hex>.<configured-zone>` primary hostname, reconcile its exact Cloudflare A record, retain custom domains as aliases, automatically install a certificate valid for the primary and aliases under Cloudflare Full (strict), and delete the owned record and certificate with the website.

**Architecture:** Keep upstream myVesta commands compatible and put provider authority in `func/vx/cloudflare/` plus thin `v-*` adapters. A root-owned atomic configuration stores the scoped token, zone ID, account email, and API-derived zone name; a separate `VX_MANAGED_DNS_PROVIDER` setting selects Cloudflare without misrepresenting the installed BIND service in `DNS_SYSTEM`. Per-domain root-owned metadata records the exact Cloudflare record and Origin CA certificate IDs used for bounded deletion. Vesta generates each private key and CSR locally, asks Cloudflare only to sign the exact Vesta primary/alias SAN set, and installs the result through native Vesta SSL commands.

**Tech Stack:** Bash, curl, jq, Vesta state files, PHP panel pages/templates, deterministic shell/PHP tests.

---

## Locked scope

- Vesta alone generates the ten-hex label. No create command or web request accepts a generated label or technical hostname.
- `v-add-web-domain` remains compatible for restore/migration/upstream internals. The panel and Vortex consumers use `v-add-vx-managed-web-domain`, whose signature has no `DOMAIN` argument.
- Cloudflare automation manages only one A record in one configured zone. TTL is Cloudflare Auto (`1`) and proxying is enabled.
- The web domain's Vesta IP/NAT state supplies the A-record target; callers cannot supply provider address, zone, record type, TTL, proxy policy, token, or record ID.
- Custom domains are Vesta aliases. The DNS-page action attaches an already-configured external domain as an alias and does not alter that external domain's DNS.
- Managed create issues one 5475-day Cloudflare Origin CA RSA certificate containing the generated hostname and complete current alias set. Alias add/remove rotates that certificate automatically; callers cannot supply hostnames, certificate material, or a certificate ID.
- Alias zones must already be proxied through Cloudflare and be accessible to the configured token with SSL and Certificates Edit. Certificate failure rolls alias/native creation back instead of publishing a Full (strict)-broken site.
- `DNS_SYSTEM` continues to identify the installed local DNS service. `VX_MANAGED_DNS_PROVIDER=cloudflare-managed` is the Vortex provider authority shown as “Cloudflare managed” in Server → Configure → DNS.
- Token, zone ID, account email, ingress address, record ID, provider response, and authorization headers never appear in argv, environment, UI, logs, history, or command output.
- Configuration and mutations are serialized with a provider lock. Configuration and record metadata are root-owned, non-symlink, mode `0600`; their parent directories are mode `0700`.
- Website deletion first verifies and revokes the exact owned Origin CA certificate and deletes the exact owned Cloudflare record, then removes metadata and continues the normal Vesta deletion. Custom-alias DNS is never deleted.
- Live Cloudflare acceptance remains intentionally pending until the operator supplies the token, zone ID, and account email after nonsecret deployment.

## Files and responsibilities

- Create `func/vx/cloudflare/main.sh`: exact config parsing, secret-safe curl transport, API error typing, provider lock, status, reconcile, cleanup, generator, and metadata authority.
- Create `bin/v-configure-vx-cloudflare`: silent/config-file credential input and validation-before-atomic-write.
- Create `bin/v-list-vx-cloudflare-status`: value-free human/JSON health.
- Create `bin/v-change-vx-dns-provider`: allow only `local` and `cloudflare-managed`.
- Create `bin/v-add-vx-managed-web-domain`: generate internally, call native web creation, reconcile, and return only the generated hostname.
- Create `bin/v-reconcile-vx-cloudflare-web-domain`: bounded `USER DOMAIN [FORMAT]` compatibility adapter.
- Create `bin/v-delete-vx-cloudflare-web-domain`: exact owned-record cleanup adapter.
- Create `bin/v-add-vx-cloudflare-web-alias`: attach an already configured custom domain as a Vesta alias.
- Create `bin/v-reconcile-vx-cloudflare-origin-ssl` and `bin/v-delete-vx-cloudflare-origin-ssl`: issue/install the exact Vesta-derived SAN certificate and revoke its exact stored ID.
- Create `func/vx/cloudflare/origin-ca-rsa.pem` and `func/vx/cloudflare/web-hooks.sh`: ship the official Cloudflare Origin CA RSA root and keep native alias changes thin while rotating or rolling back certificates.
- Modify `bin/v-add-web-domain-alias` and `bin/v-delete-web-domain-alias`: invoke the VX certificate hook only for managed sites.
- Modify `bin/v-list-sys-config`: expose only the bounded nonsecret managed-provider enum to the existing server form.
- Modify `bin/v-delete-web-domain`: thin managed-record cleanup hook before destructive local deletion.
- Modify `bin/v-change-web-domain-name`: reject rename of Vesta-managed technical hostnames.
- Modify `web/add/web/index.php` and `web/templates/admin/add_web.html`: remove caller primary-domain input, make custom domains the visible alias input, and consume the generated hostname returned by the Vortex command.
- Create `web/add/vx-cloudflare-domain/index.php` and `web/templates/admin/add_vx_cloudflare_domain.html`: admin-only CSRF-protected external-domain alias form.
- Modify `web/templates/admin/list_dns.html`: add the requested adjacent Cloudflare-domain button.
- Modify `web/edit/server/index.php` and `web/templates/admin/edit_server.html`: provider selector and sanitized configuration state/instructions.
- Create `test/cloudflare/test-cloudflare-managed-domains.sh`: stubbed provider and lifecycle acceptance.
- Create `test/test_cloudflare_web_ui.php`: source-contract coverage for CSRF, escaping, ownership, generated-domain input removal, DNS button, and provider selector.
- Create `.docs/user-guides/vesta-cloudflare-managed-dns.md`: operator configuration, rotation, status, recovery, and credential requirements.
- Modify `.docs/README.md`: index the guide and this plan.

## Integrated implementation milestone

### Task 1: Provider authority and exact record lifecycle

- [ ] **Step 1: Add a failing provider-stub test**

The test creates a synthetic Vesta root and fixed curl stub. It asserts `not_configured`, atomic mode-`0600` configuration, value-free output, create/no-op/update/readback, duplicate rejection, malformed/401/403/429/timeout failures, and exact idempotent deletion. It also inspects captured process arguments and environment to prove protected values are absent.

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected before implementation: `FAIL: missing Cloudflare helper or command`.

- [ ] **Step 2: Implement the minimal provider helper and adapters**

Public contracts:

```text
v-configure-vx-cloudflare [--config-file ROOT_ONLY_FILE]
v-list-vx-cloudflare-status [json]
v-change-vx-dns-provider local|cloudflare-managed
v-reconcile-vx-cloudflare-web-domain USER DOMAIN [json]
v-delete-vx-cloudflare-web-domain USER DOMAIN [json]
```

Provider transport uses a temporary mode-`0600` curl config containing URL, method, headers, body-file path, output path, and timeouts. Runtime argv is only `/usr/bin/curl --config <temporary-path>` under an empty environment. JSON responses remain in bounded temporary files and only stable codes such as `ready`, `not_configured`, `unauthorized`, `rate_limited`, `timeout`, `malformed_response`, `ambiguous_record`, `created`, `unchanged`, `updated`, and `deleted` leave the helper.

- [ ] **Step 3: Run the focused provider test**

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected: all provider and lifecycle assertions pass without a network request.

### Task 2: Vesta-owned website identity and cleanup

- [ ] **Step 1: Extend the failing lifecycle fixture**

Assert two generated labels match `^s-[a-f0-9]{10}$`, differ, contain no user/alias material, and are never accepted as input. Assert aliases are passed to native web creation, collisions retry, a successful create has exact record metadata, rename is rejected, and native deletion removes the exact record before the local domain.

- [ ] **Step 2: Implement the managed creation surface and thin hooks**

Public create contract:

```text
v-add-vx-managed-web-domain USER [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS] [native proxy long options]
```

It reads the configured zone name, makes five random bytes with `/dev/urandom`, encodes ten lowercase hex characters, performs bounded Vesta/provider collision checks, calls `v-add-web-domain`, reconciles/readbacks Cloudflare, and emits only the resulting technical hostname. The generic native create contract remains unchanged.

- [ ] **Step 3: Re-run the focused lifecycle test**

Run: `bash test/cloudflare/test-cloudflare-managed-domains.sh`

Expected: generated identity, aliases, immutable rename, and create/delete order pass.

### Task 3: Panel delivery

- [ ] **Step 1: Add a failing PHP source-contract test**

Assertions require the web controller to call `v-add-vx-managed-web-domain` without `v_domain`, require the template to have no editable/posted primary-domain input, require the alias form to preserve CSRF and `escapeshellarg`, require admin authorization, require the DNS toolbar link, and require the server provider selector to call only `v-change-vx-dns-provider`.

Run: `php test/test_cloudflare_web_ui.php`

Expected before implementation: `FAIL` on the missing Vortex panel surfaces.

- [ ] **Step 2: Implement the thin PHP/template integration**

The add-web page treats custom domains as aliases, obtains the generated hostname from the successful command response, and then uses that server result for existing FTP/SSL/stats flows. The new DNS toolbar form attaches an already-configured custom hostname to a selected owned web domain. Server configuration displays local versus Cloudflare-managed provider mode and only a configured/not-configured credential status.

- [ ] **Step 3: Run focused UI tests and syntax checks**

Run:

```bash
php test/test_cloudflare_web_ui.php
php -l web/add/web/index.php
php -l web/add/vx-cloudflare-domain/index.php
php -l web/edit/server/index.php
```

Expected: tests pass and every file reports `No syntax errors detected`.

### Task 4: Documentation, issue, deployment checkpoint, and the single audit

- [ ] **Step 1: Document the operator workflow and update issue #5**

The guide records the least-privilege token (Zone Read and DNS Read/Edit for one zone), secure interactive/config-file setup, provider selection, health, create/delete semantics, recovery, and rotation. Issue #5 receives this locked implementation plan and explicitly notes that api-vxapp #145 must consume the Vesta allocator before claiming Vesta-owned API Site generation.

- [ ] **Step 2: Run the one integrated validation/audit loop**

Run exactly once after implementation:

```bash
bash -n func/vx/cloudflare/main.sh func/vx/cloudflare/web-hooks.sh bin/v-configure-vx-cloudflare bin/v-list-vx-cloudflare-status bin/v-change-vx-dns-provider bin/v-add-vx-managed-web-domain bin/v-reconcile-vx-cloudflare-web-domain bin/v-delete-vx-cloudflare-web-domain bin/v-add-vx-cloudflare-web-alias bin/v-reconcile-vx-cloudflare-origin-ssl bin/v-delete-vx-cloudflare-origin-ssl bin/v-add-web-domain-alias bin/v-delete-web-domain-alias bin/v-delete-web-domain bin/v-change-web-domain-name
bash test/cloudflare/test-cloudflare-managed-domains.sh
php test/test_cloudflare_web_ui.php
php -l web/add/web/index.php
php -l web/add/vx-cloudflare-domain/index.php
php -l web/edit/server/index.php
git diff --check
```

One independent reviewer checks the complete diff for specification, secret safety, exact deletion authority, and regressions. Any numbered blocker is fixed once and rechecked only against that blocker.

- [ ] **Step 3: Commit and deploy the nonsecret implementation**

Commit the coherent feature, follow `.docs/user-guides/vesta-control-plane-releases.md`, install only the changed root-owned files on `debian@192.168.100.100`, and prove file modes, PHP/Bash syntax, panel route availability, and sanitized `not_configured` status. Do not enter or transmit real credentials during this step.

- [ ] **Step 4: Stop at the protected live-acceptance boundary**

Request the Cloudflare API token, zone ID, and account email. After they are supplied, configure through protected input, select Cloudflare-managed mode, create and delete one disposable site, prove API readback and public DNS, and record only sanitized acceptance evidence.

## Acceptance checklist

- [ ] Every panel-created site has a Vesta-generated immutable `s-<10 hex>.<zone>` primary hostname.
- [ ] No caller can provide the generated label/hostname to the managed create surface.
- [ ] Custom domains are aliases; the DNS-area action attaches an already configured external domain without mutating its DNS.
- [ ] Managed create and alias mutation automatically install a certificate whose SANs exactly cover the generated hostname and all current aliases, so Cloudflare Full (strict) succeeds.
- [ ] Private keys remain on Vesta; superseded/deleted exact Origin CA certificate IDs are revoked.
- [ ] Technical A-record create/no-op/update/readback and exact idempotent deletion work.
- [ ] Website deletion cannot leave a known owned record behind or delete any broader record set.
- [ ] Provider selection is visible in Server → Configure → DNS while installed `DNS_SYSTEM` remains intact.
- [ ] Credentials and provider values never leak through argv, environment, output, logs, UI, test evidence, or Git.
- [ ] Stubbed validation, syntax checks, one combined audit, commit, and nonsecret target deployment complete before requesting real credentials.

## Cross-repository dependency

- Owner: `jackpridham/vesta-vxapp` owns hostname allocation, Cloudflare configuration, record lifecycle, panel creation, and external-domain alias attachment.
- Consumer: [api-vxapp#139](https://github.com/jackpridham/api-vxapp/issues/139) must call the Vesta allocator/reconcile contract without receiving Cloudflare credentials or choosing the generated hostname.
- Contract correction: [api-vxapp#145](https://github.com/jackpridham/api-vxapp/issues/145) currently allocates `s-<32 hex>` inside api-vxapp. It must be revised before API-created Sites can claim the Vesta-owned `s-<10 hex>` contract requested here; this implementation does not silently mutate that separate repository.
- Full production proof remains in [api-vxapp#227](https://github.com/jackpridham/api-vxapp/issues/227) after this owner implementation passes protected live acceptance.

## Non-goals

- General-purpose Cloudflare DNS CRUD, record backup, cache purge, multiple-zone management, or customer-zone discovery.
- Copying the broad `vortex-scripts` command surface or its argv-visible authorization header pattern.
- Mutating DNS for custom aliases that the operator says are already configured.
- Replacing BIND/named service lifecycle or changing restore/migration compatibility commands.
- Treating provider API success as public propagation, certificate readiness, proxy health, or production authorization.
