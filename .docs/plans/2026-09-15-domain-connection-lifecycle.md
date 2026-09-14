# Domain Connection Lifecycle Implementation Plan

**Workflow:** Milestone-Driven; Vesta, the API, and the customer UI deliver one compatible lifecycle.
**Goal:** Connect customer domains with automatic HTTPS while customers retain their DNS provider and every site retains its permanent technical URL.
**Architecture:** Cloudflare manages and proxies Vortex technical hostnames. A separate DNS-only Vortex connection target points to Vesta. Customer hostnames use separate native Vesta web domains and Let's Encrypt HTTP-01 certificates, linked to the same site.
**Authority:** The user's 2026-09-15 instruction to simplify around this split; repository `AGENTS.md`; the [current Cloudflare guide](../user-guides/vesta-cloudflare-managed-dns.md) and [native proxy guide](../user-guides/native-web-domain-proxy.md). This revision replaces the earlier provider-selection proposal.
**Claim boundary:** This is an implementation plan. It does not change the deployed [Cloudflare lifecycle](2026-08-25-vesta-cloudflare-managed-domains.md), authorize production mutations, or establish that the new connection path has passed live acceptance.

## Selected approach

| Name or responsibility | Implementation |
| --- | --- |
| Permanent site URL, `s-<id>.vxapp.io` | Existing Vesta-generated identity, proxied Cloudflare DNS, and technical Origin CA certificate. |
| Connection target, proposed `connect.vxapp.io` | One shared DNS-only record pointing to the admitted Vesta public ingress. Managed in Vortex's existing Cloudflare zone; this plan does not create it. |
| Customer `www` or other subdomain | Customer creates a CNAME to the connection target at their existing DNS provider. |
| Customer root domain | Customer creates an A record to the published ingress IPv4 address. ALIAS/ANAME/flattening to the connection target is optional where supported. Publish AAAA instructions only after that ingress's IPv6 path passes acceptance. |
| Customer HTTPS | Native Vesta web vhost with its own publicly trusted Let's Encrypt certificate and Vesta-owned renewal. |
| Site routing | Technical and customer vhosts use the same authoritative site/backend binding. A DNS alias does not rewrite the browser's hostname. |
| DNS ownership | Customers keep their registrar, nameservers, mail records, and DNS account. No customer BIND zone or tenant API token is needed. |

The connection target must stay DNS-only throughout its CNAME chain. A CNAME to the proxied technical URL would send customer traffic through Vortex's Cloudflare proxy again. DNS-only resolution directs traffic to the origin; it does not provide Vortex's Cloudflare proxy/WAF coverage. [Cloudflare proxy behavior](https://developers.cloudflare.com/dns/proxy-status/).

Use native HTTP-01 validation: Vesta serves the challenge for the exact customer hostname on public port 80, then installs and renews its certificate. Customers do not supply DNS credentials. A separate connection-specific TXT proof binds the hostname to the correct tenant/site before publication; a stale CNAME to the shared target is insufficient. [Let's Encrypt challenge behavior](https://letsencrypt.org/docs/challenge-types/#http-01-challenge).

A root domain and `www` are separate connections. Both must work before advertising both URLs. A customer's existing CDN/proxy may remain only where challenge delivery and verified HTTPS pass the compatibility tests; we never log in to or modify their provider.

**Removed from this plan:** Cloudflare for SaaS, Custom Hostnames APIs, Enterprise/apex-proxying evaluation, provider selection, a provider abstraction, and tenant-zone SSL-setting checks. DNS hosting, nameserver migration, wildcard certificates, automatic DNS login, domain transfers, new queue infrastructure, and a new edge service are outside this implementation.

## Native Vesta representation and ownership

Keep the technical identity under its existing Cloudflare DNS/Origin CA lifecycle. New technical sites have no customer aliases; legacy alias removal belongs to Milestone 3. Create each verified customer hostname as a separate native web-domain row using `ALIASES=none` so its persisted alias list is empty, explicitly linked to the technical site. Reuse native `v-add-web-domain` internally, not the combined web/DNS/mail command or the product allocator. Customer rows are connection children, not additional application Sites records.

This separation is required by today's implementation: `vx-proxy.stpl` selects certificate files per native domain, while aliases share their parent's certificate. Attaching customer aliases to the managed technical row would re-enter the full-SAN Origin CA rotation. Customer rows must have no Cloudflare record/certificate metadata; technical rows must not enter Let's Encrypt renewal.

Copy and validate the technical site's complete persisted `PROXY_*` binding into each child, including profile, Host preservation, trusted BusinessGUID headers, path/mode, timeouts, and backend. Never infer ownership from a shared IP/backend or accept these settings from the customer. Each child consumes existing `WEB_DOMAINS` quota; preflight this explicitly and show the available connection capacity. Do not bypass package limits or silently use the alias quota.

| Authority | Stored responsibility |
| --- | --- |
| Vesta native `web.conf` | Technical and child vhosts, proxy configuration, native certificate/renewal state. |
| Vesta connection registry | Exact normalized hostname → owner, technical parent, native child, connection ID, generation, proof, desired/observed state, and cleanup progress. |
| API tenant database | Site-scoped connection intent, idempotency key, Vesta ID, retry/delivery state, and sanitized observed status. |
| UI/shared store | Typed DNS instructions, progress, primary selection, and technical preview link. |

Retain the proposed root-owned `data/vx/domain-connections/hostnames/<hostname-sha256>.json` registry. Validate the hostname inside the record; use atomic writes, mode `0600`, mode `0700` directories, non-symlink paths, short reservation locks, and per-connection generation/lease checks. This is the single ownership authority across all Vesta users. The first release uses one Vesta authority; a second independent controller requires shared reservations first. Tenant-local SQL uniqueness cannot provide that guarantee.

The shared connection-target record is infrastructure owned by Vesta configuration, separate from per-site technical records. Persist its exact record identity and ingress in root-owned connection configuration; reuse the existing secret-safe Cloudflare transport. Reconcile it with the existing zone-scoped credential, without weakening the technical record's `proxied=true` invariant. Site/connection deletion must never delete the shared target. An ingress change requires coordinated validation of affected sites; customers using apex A records may need to update their own records.

## Lifecycle and interfaces

`pending_verification → pending_dns → pending_tls → connected`

A connected domain can become `degraded`. Deletion proceeds through `disconnecting → disconnected`; terminal input errors are `failed`, and uncertain partial mutations are `recovery_required`. Include a stable reason, component observations, generation, `lastCheckedAt`, `lastSuccessfulAt`, and `nextCheckAt`. Cached success is not a permanent health guarantee.

- Normalize lowercase IDNA hostnames, terminal dots, and label/total lengths consistently. Reject URLs, ports, IP literals, wildcards, and reserved platform names. Correctly classify suffixes such as `.com.au` using an existing maintained implementation.
- Bind fresh TXT proof to the connection/site/generation; expire unused reservations and apply tenant quotas. Check current native primary/alias ownership as well as the registry, including legacy sites.
- Create no tenant-content route before proof. Before certificate acceptance, expose only the required challenge/holding response; unknown Hosts must never reach another tenant.
- Check actual DNS routing, including conflicting AAAA, CAA, DNSSEC, and propagation failures. Pin public probes to approved ingress and validate redirects/IPv4/IPv6 destinations so customer DNS cannot induce private-network requests.
- Mark connected only after certificate installation, native config validation, and public HTTPS serving the expected site's identity/content. Keep technical-site creation and editing independent of pending customer DNS.
- Use one bounded connection worker for verification, initial issuance, retry, and observation. Keep native `v-update-letsencrypt-ssl` as the only certificate-renewal scheduler; coordinate child locks and record renewal results. Do not introduce a competing renewer or wait for propagation in an HTTP request.
- Disconnect switches a selected primary back to the technical URL, stops customer content on the child, cancels stale work, and cleans up only owned child resources. Retain reservations/recovery records until cleanup is known. Transient degradation retains ownership and the user's primary selection.
- Back up/restore the explicit relationship and recovery state with native certificate material under existing protection rules. Restore checks current ownership before routing. Expose renewal failures, certificate expiry, overdue work, and worker health in existing operator status/monitoring.

Proposed thin commands, preserving legacy command signatures:

```text
v-add-vx-web-domain-connection USER TECHNICAL_FQDN HOSTNAME REQUEST_ID [json]
v-list-vx-web-domain-connections USER TECHNICAL_FQDN [json]
v-reconcile-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-delete-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-update-vx-web-domain-connections [json]
```

Create durably records pending work and is idempotent for identical `REQUEST_ID` input. Lists are cached, read-only observations. Reconcile performs one bounded attempt. Use the existing authenticated command boundary and a versioned capability response; grant no direct tenant sudo. Enrollment can be disabled without disabling renewal or cleanup of existing connections.

API routes under `/v{version}/Sites`:

| Method and suffix | Behavior |
| --- | --- |
| `POST /{siteGUID}/Domains` | Validate owner and hostname; persist idempotent intent; return `202` and pending status. |
| `GET /{siteGUID}/Domains[/{domainGUID}]` | List/read tenant-owned connections, instructions, and observation freshness. |
| `POST /{siteGUID}/Domains/{domainGUID}/Check` | Rate-limited request for a fresh asynchronous check. |
| `PATCH /{siteGUID}/Domains/{domainGUID}` | Select a currently accepted connection as primary; changing hostname creates a new connection. |
| `DELETE /{siteGUID}/Domains/{domainGUID}` | Queue disconnect; return `202` until cleanup finishes. |

Register explicit named routes and matching permissions before the CRUD catch-all. Site responses always expose `technicalURL`; `webURL` uses an accepted primary or the technical URL. Show degraded status without silently changing a still-selected primary. Existing synchronous alias writes require a documented versioned transition, not an undocumented change to pending-success semantics.

## Implementation milestones

Paths are relative to the named repository. New paths below are planned deliverables. Read each repository's current instructions and matching skills before editing. Product documentation belongs in its repo; server changes and evidence belong in `vortex-scripts/Servers/<hostname>/`.

### Milestone 1: Connect customer domains directly through native Vesta

**Authority:** The selected DNS/TLS split and ownership/lifecycle rules above.
**Depends on:** None for local work. Live proof uses separately authorized disposable domains and a named test ingress.
**Owned paths:** New Vesta `.docs/contracts/domain-connections.md`, `func/vx/domain-connections/`, the five commands above, and `test/domain-connections/test-state.sh` / `test-native-tls.sh`. Narrow integration in `func/vx/cloudflare/main.sh`, `func/vx/cloudflare/web-hooks.sh`, `func/vx/proxy.sh`, `func/domain.sh`, `func/rebuild.sh`, `bin/v-configure-vx-cloudflare`, `bin/v-add-web-domain`, `bin/v-add-letsencrypt-domain`, `bin/v-update-letsencrypt-ssl`, `bin/v-update-sys-queue`, `bin/v-backup-user`, `bin/v-restore-user`, and `web/api/index.php`. Mirror affected `vx-proxy.tpl/.stpl` defaults in applicable installer and synthetic-root template directories.

**Behavior:** Implement the shared DNS-only target setup/readback, registry, native child creation, challenge-only staging, certificate acceptance, retries, renewal observation, and exact cleanup. Freeze a capability contract containing the connection target, supported ingress families, states, and public DNS instructions.

Preserve the technical site's current Cloudflare guards. Add child lifecycle guards for alias changes, rename, IP, template/backend/proxy edits, manual SSL, suspension, and domain/user bulk deletion. Native initial issuance and scheduled renewal must have a narrow authorized path through those guards. In particular, `v-add-letsencrypt-domain` uses native delete/add SSL commands during installation: retain the last accepted certificate/config and recover if replacement fails. Initial creation must not implicitly add `www`.

Persist operation intent before mutation, reconcile a lost native-command response by exact ownership/readback, and reject stale generations. Native rebuilds and restores must reconstruct the same parent/child TLS boundaries. Use existing config checks and service controls; disclose shared restart effects rather than assuming every native call reloads gracefully.

**Exclusions:** No customer DNS/BIND records, customer Cloudflare API calls, new TLS proxy, custom ACME client, or broad relaxation of native managed-SSL guards.

**Focused proof:** `bash test/domain-connections/test-state.sh`; `bash test/domain-connections/test-native-tls.sh`; `bash test/cloudflare/test-cloudflare-managed-domains.sh`; `bash test/cloudflare/test-cloudflare-native-lifecycle.sh`; `bash test/test_web_domain_proxy.sh`. Cover concurrent claims, implicit-alias prevention, quota failure, proof expiry, unsafe probe addresses, challenge precedence, exact SNI certificates, lost responses, renewal/install failure, stale jobs, target deletion protection, rebuild, and restore conflicts. Run `bash -n` on touched Bash and `php -l` on touched PHP.

Add `test/domain-connections/run-native-acceptance.sh`: `bash test/domain-connections/run-native-acceptance.sh --config-file /run/vx-domain-acceptance/config.json` inspects only; `--apply` enables explicitly authorized disposable test mutations. Require a protected config naming allowed domains and ingress, and redact private material. Prove external `www` CNAME, apex A, public port-80 challenge, valid customer HTTPS, retained technical HTTPS, and certificate replacement on two distinct test sites. Validate both ordinary external DNS and a customer-controlled proxy where supported. No `curl -k`; distinguish staging rotation from an actual scheduled production renewal.

### Milestone 2: Deliver the customer connection workflow through API and UI

**Authority:** Milestone 1 contract and existing API tenant/route/migration conventions.
**Depends on:** Milestone 1's frozen interface. API and UI may develop against shared fixtures while Vesta integration completes.
**Owned paths:** In `api-vxapp`, new `api/src/vortex/ServicesV2/Sites/Domains/` and a new direct entry in `api/src/vortex/ServicesV2/Sites/Migrations/`; existing Sites `Database/SitesCreateTables.php`, `Operations/SiteOperations.php`, `Operations/SiteOperationsFactory.php`, `Enums/SiteField.php`, `Enums/SiteProjectionField.php`, `Validators/SiteFieldValidator.php`, `Formatters/SitesResponseFormatter.php`, and `Inspection/VestaSiteInspector.php`. Extend `api/src/vortex/Vesta/Sites/`, `api/src/vortex/Vesta/Enums/VestaApiCommand.php`, `api/src/vortex/Routes/SitesRoutes.php`, `api/src/vortex/Routes/DataProviders/SitesRoutes.json`, and the existing cron registration boundary.

In `vue-vxapp-team-ci` (the `vue-vxapp` checkout), use `src/components/Forms/Sites/SiteIdentityInputs.vue`, `siteFormData.ts`, `src/views/apps/sites/SiteSummaryCard.vue`, `SiteConfigurationCard.vue`, `SiteFormPage.vue`, `SitePreviewPage.vue`, and `src/components/ServiceLists/Sites/siteListPresentation.ts`. Shared store changes belong in `stores-vxapp` through `src/@vxapp/Sites/useSiteStore.ts`; generate enum/contracts from their API source. Vesta panel changes use `web/add/vx-cloudflare-domain/index.php`, `web/templates/admin/add_vx_cloudflare_domain.html`, and relevant native web list/edit views.

**Behavior:** Implement the authenticated routes, durable request delivery, idempotency, tenant-scoped projections, and primary selection. Reuse the outbox pattern in `ServicesV2/Orders/Events/` with Sites-specific data; `Sites/RuntimeRefresh/` remains the slave-runtime delivery queue and is notified after accepted domain/primary changes. Vesta retains hostname ownership authority. API inspection understands linked native children instead of flagging their absence from the technical ALIAS list as drift.

Present “Connect domain”: hostname entry, TXT proof and routing records to copy, progress, last checked time, retry, primary selection, and disconnect. Always retain technical preview. Group native child rows under their site in product presentation without creating duplicate application sites; show existing quota consumption honestly. The existing Vesta admin flow uses the same lifecycle and keeps its admin/CSRF/owner checks.

Preserve current site-create ordering and trusted backend configuration. Define legacy alias-field compatibility before removing writes; old fields may remain read projections. Site deletion records intent, cancels older jobs, disconnects children, then removes technical infrastructure and application state, retaining recovery authority on failure. Publish API/store/UI contract changes together; follow each submodule's commit/push and pointer rules when implementation is authorized.

**Exclusions:** No DNS-provider SDK in the API, new generic Domain service, raw child-as-site CRUD, caller-supplied technical FQDN, or customer credential form.

**Focused proof:** New API tests: `composer test:file -- api/src/tests/ServicesV2/Sites/Domains` and `composer test:file -- api/src/tests/Integration/ServicesV2/Sites/Domains`. Existing regressions: `composer test:file -- api/src/tests/Vesta/Sites/VestaManagedSiteLifecycleTest.php`; `composer test:file -- api/src/tests/ServicesV2/Sites/SiteOperationsTest.php`; `composer test:file -- api/src/tests/ServicesV2/Sites/SitesResponseFormatterTest.php`; `composer test:file -- api/src/tests/ServicesV2/Sites/SitesRoutesRegistrationTest.php`. Cover tenant isolation, failed commits, lost Vesta responses, retry/restart, child-aware inspection, primary races, and interrupted deletion. Run `./validate.sh --changed`, `composer analyse:changed`, and read-only `composer migrations:list -- --json`; migration mutation tests use isolated databases.

UI checks: `pnpm exec vitest --run src/components/Forms/Sites/__tests__/SiteIdentityInputs.spec.ts src/views/apps/sites/__tests__/SiteSummaryCard.spec.ts src/views/apps/sites/__tests__/SiteFormPage.spec.ts src/@vxapp/Sites/__tests__/useSiteStore.spec.ts`; `pnpm run type-check`; `pnpm run validate`; `bash tools/e2e/runManagedLocalPlaywright.sh e2e/sites/sites-crud.spec.ts --project=chromium`. Exercise pending DNS through connected, degraded, retry, primary, and disconnect. In Vesta run `php test/test_cloudflare_web_ui.php` and lint changed PHP/JavaScript.

### Milestone 3: Adopt existing sites while preserving service

**Authority:** The selected native-child model and the read-only SydVortex migration audit.
**Depends on:** Milestones 1–2 infrastructure/API contracts; may proceed alongside customer UI work.
**Owned paths:** New `install/migrations/domain-connections/`, `test/domain-connections/test-migration.sh`, and `.docs/user-guides/domain-connections.md`; shared migration helpers under `func/vx/domain-connections/`. Preserve the legacy `install/migrations/cloudflare-managed-web-domains/` path and its guard tests. Eventual host rollout plans/reports remain in `vortex-scripts/Servers/SydVortex/`.

**Behavior:** Implement write-free assessment, explicit preparation, revision-bound apply, and drift-aware rollback. Inventory native rows/aliases, DNS, certificate authority and expiry, existing LE enrollment, proxy binding, quota, and all shared-service effects. Registry import alone is not ownership or HTTPS proof.

For legacy sites whose primary is already the customer domain, retain/adopt that native row and valid LE certificate; provision the new technical parent separately. Split `www` out only through a prepared transition that avoids duplicate server names and preserves both URLs.

An existing alias cannot also be registered as a native primary: Vesta rejects that namespace collision. For managed aliases, prepare only non-conflicting proof/recovery state and inactive configuration before a controlled ownership transfer. Transfer the name from the technical alias list to its native child, establish challenge delivery and public TLS, and then retire the old SAN/route authority. The ordinary managed alias-delete command immediately rotates the Origin CA certificate, so the migration must explicitly coordinate that cleanup with replacement readiness rather than chaining ordinary delete/add calls. Keep the old served certificate/config recoverable; a handover that cannot preserve service fails acceptance. If existing DNS still reaches Vortex's proxy, arrange a separate customer DNS cutover. Never activate duplicate server names or promise a DNS-free migration for every existing site.

Future production targets are `Jack9f6fa` sites `castlesoncommand.com.au`, `nextgenerationhoardings.com.au`, and `newcastleslushiehire.com.au`, including each `www`. Reinspect before rollout and migrate one site first. Preserve their complete native `vx-proxy` binding. Do not disable existing renewal until the accepted successor owns it.

**Exclusions:** No execution of today's blocked migration, direct customer DNS edits, broad rollback over later user changes, or unrelated workload cleanup. This plan does not authorize those production migrations.

**Focused proof:** `bash test/domain-connections/test-migration.sh`; `bash test/cloudflare/test-cloudflare-managed-web-domain-migration.sh`; `bash test/cloudflare/test-cloudflare-native-migration-ssl-capability.sh`; `bash test/cloudflare/test-cloudflare-native-migration-rebuild-capability.sh`. Cover unchanged assessment hashes, same-name native adoption, technical allocation, alias splitting, cert handover, failed reload/restart, partial cleanup, replay, quota limits, and rollback refusing drift. Assert apex and `www` remain mapped to the right site throughout the accepted cutover.

### Milestone 4: Accept the complete product and prepare release

**Authority:** All milestones and the current Vesta deployment/release instructions.
**Depends on:** Milestones 1–3; this is the integrated review and comprehensive validation checkpoint.
**Owned paths:** The Vesta contract, customer guide, current Cloudflare guide, `.docs/README.md`, and release validation evidence; API route/technical docs and `MIGRATIONS.md`; shared contracts and frontend docs where affected. Actual server configuration, exposure, operational evidence, and recovery records belong beside the owning server record.

**Behavior:** Accept create → technical preview → proof → DNS → customer HTTPS → primary → renewal/recovery → disconnect → delete across two test tenants. Verify direct public ingress on 80/443, correct certificates and site binding, no spoofed cross-tenant headers/cache content, and stable technical HTTPS. Test conflicting AAAA/CAA, DNS removal, LE rate limits/unavailability, renewal failure, lost jobs, process restart, and exact cleanup. Default customer traffic reaches Vesta directly; verify that the admitted ingress supports this rather than assuming it accepts only Cloudflare source addresses. Any required live listener/firewall changes need their own named authorization.

Release order: Vesta capability with enrollment disabled; additive API schema/worker/contracts; store/UI consumers; then enable enrollment after compatibility and renewal checks. Stopping enrollment must preserve existing renewal and cleanup. Keep a rollback version that understands native child authority. Reconcile guides by explicit lifecycle version so legacy instructions remain accurate for unmigrated sites. Prepare exact releases, target scope, shared-service impact, and recovery material before requesting any production rollout authorization.

**Exclusions:** No production deployment inferred from local/staging success. Controlled certificate rotation proves the mechanism; it does not prove a future scheduled production renewal.

**Focused proof:** Run the final changed-domain suites and Vesta `bash test/compose/run-production-readiness-limited.sh`. In the authorized API test environment run `bash scripts/run-e2e.sh -- vendor/bin/phpunit --no-coverage --fail-on-skipped api/src/tests/E2E/SitesE2ETest.php` with the domain journey added to that suite. Run the Milestone 2 managed browser journey and Milestone 1 native acceptance against the compatible revisions. Record redacted evidence, review integration, reconcile docs, verify paths/links, run `git diff --check`, and commit only task-owned changes.

## Execution ledger and handoff

Use `$milestone-driven-implementation` as the sole execution coordinator when implementation is authorized. Link one successor owner issue in `jackpridham/vesta-vxapp` for milestone state, revisions, evidence, and the numbered blockers below. This documentation revision publishes no issue or comment. API and UI work may proceed in parallel against Milestone 1's frozen contract; migration proceeds after the Vesta/API behavior stabilizes. Reserve broad review and closeout for Milestone 4.

[Vesta #5](https://github.com/jackpridham/vesta-vxapp/issues/5) records the original implemented lifecycle. [Vesta #6](https://github.com/jackpridham/vesta-vxapp/issues/6) is optional admin/DNS work, not a prerequisite; coordinate only overlapping files. Reconcile [API #139](https://github.com/jackpridham/api-vxapp/issues/139) and its related recovery, readiness, and E2E issues with this contract during authorized execution; preserve completed migration history. Do not implement the earlier customer-zone/one-certificate assumptions as new requirements.

Implementation progress, compatible revisions, review findings, validation,
and deployment evidence are tracked in the sole [execution ledger on Vesta
#7](https://github.com/jackpridham/vesta-vxapp/issues/7#issuecomment-5669043128).
The requirements below remain acceptance criteria; code completion alone does
not establish live acceptance. One blocker list:

1. **Native integration proof:** Separate SNI certificates, challenge-only staging, child-aware guards, quotas, and renewal/rollback must pass Milestone 1. The TLS implementation is selected; provider selection is no longer a blocker.
2. **Test resources and ingress:** Name disposable domains and allowed DNS/host mutations before live acceptance. Confirm public 80/443 and any IPv6 path; offline implementation can proceed independently.
3. **Compatible consumers:** Freeze routes/capability, migrate alias-field consumers, and identify the Vesta/API/store/UI release set before enrollment.
4. **Production adoption:** Obtain fresh state, exact release/target authorization, and verified recovery material for the three `Jack9f6fa` sites at rollout.

The 2026-09-15 read-only baseline remains Vesta `c9474c16be4f7160d11cb8b7395b1e53ebad8ad2`, API `87dae3ba83b76f6f776bb881c1ff50adafcc7abe`, and Vue `1d7dc7a223747dba17f007155dfb72183d82bf4d`; recheck drift before implementation. Production evidence is in `vortex-scripts/Servers/SydVortex/Reports/cloudflare-jack9f6fa-migration-validation/REPORT_cloudflare-jack9f6fa-migration-validation_20260915-0319.md`.

Requirements trace: Cloudflare technical DNS and direct customer TLS → Milestone 1; ownership, retries, and renewal → 1–2; customer-managed DNS and usable connection UI → 2; existing-site continuity → 3; compatibility, isolation, and controlled release → 4.
