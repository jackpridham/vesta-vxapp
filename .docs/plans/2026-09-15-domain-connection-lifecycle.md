# Domain Connection Lifecycle Implementation Plan

**Workflow:** Milestone-Driven; Vesta, the application API, shared contracts, and the customer UI must deliver one compatible lifecycle.
**Goal:** Let customers connect their own domains, obtain HTTPS, monitor connection health, and disconnect safely while retaining their DNS provider and a working permanent site URL.
**Architecture:** Keep Vesta as the website and infrastructure authority. Add a persistent domain-connection lifecycle beside technical-site provisioning; the API owns tenant requests and durable delivery, and the UI presents DNS instructions and observed readiness. Select one HTTPS implementation after proving apex support, origin verification, renewal, and cost.
**Authority:** The user's 2026-09-15 request for a durable web-builder domain-connection plan; repository `AGENTS.md`; the [current Cloudflare guide](../user-guides/vesta-cloudflare-managed-dns.md), [implemented design](2026-08-25-vesta-cloudflare-managed-domains.md), and [native proxy guide](../user-guides/native-web-domain-proxy.md) establish the behavior being evolved.
**Claim boundary:** Proposed implementation scope, not approval to deploy, purchase provider features, expand credentials, change customer DNS, or run a production migration. This planning turn changes documentation only. Completion of development gates establishes release readiness; production and real renewal observations require their own evidence.

## Product outcome and current gap

A customer creates a site and receives its Vesta-generated `s-<id>.vxapp.io` URL. Later, they enter a domain, add the displayed DNS records at their existing provider, and see verification, DNS, and HTTPS progress. Editing and previewing the site continue while connection is pending. Once connected, they may make the domain primary. Removing a domain leaves the site and technical URL available.

The present implementation couples custom aliases to token-accessible customer Cloudflare zones, customer-zone SSL settings, and a shared Origin CA certificate covering the technical hostname plus every alias. The API patches aliases synchronously, and its response formatter prefers a customer domain without a separate connection-readiness contract. These are the boundaries to replace; immutable Vesta-generated identity and synchronous technical-site readiness remain useful.

Inspection baseline: Vesta `c9474c16be4f7160d11cb8b7395b1e53ebad8ad2`, API `87dae3ba83b76f6f776bb881c1ff50adafcc7abe`, and Vue checkout `1d7dc7a223747dba17f007155dfb72183d82bf4d`. Recheck drift before implementation. The read-only production audit is owned by `vortex-scripts/Servers/SydVortex/Reports/cloudflare-jack9f6fa-migration-validation/REPORT_cloudflare-jack9f6fa-migration-validation_20260915-0319.md`; it found working customer sites and inaccessible customer zones, not a safe migration through the current script.

## Locked boundaries for this proposal

| Boundary | Required behavior |
| --- | --- |
| Site identity | Only Vesta allocates the immutable technical FQDN. Customer DNS or certificate delays do not block technical-site creation, editing, or preview. |
| Customer control | Customers retain their registrar, nameservers, DNS, and mail records. Connection requires explicit DNS proof/routing instructions, never a tenant Cloudflare token. |
| Platform control | Vesta owns platform DNS, connection reservations, provider objects, certificate operations, routing, and cleanup. The API never generates technical hostnames or calls Cloudflare directly. |
| DNS hosting | Zone creation/import, registrar services, MX editing, and general DNS CRUD are a separate optional product. Account-wide token access is not a dependency. |
| Root domains | Apex and `www` are separate connections with separate status and certificate coverage. An apex must have a supported path without requiring a nameserver move. No silent `www`-only substitution. |
| Publication | Only a verified, correctly routed, HTTPS-ready connection can first become primary. DNS pointing at a shared platform target alone is insufficient ownership proof. |
| TLS | Verify browser-facing certificates and the edge-to-origin connection. Never resolve provider incompatibility by disabling verification, using Flexible/unchecked Full, or asking tenants to weaken their zone policy. |
| Compatibility | Keep the existing managed-domain contract until a site explicitly uses the new version. Do not silently reinterpret synchronous legacy alias success as pending success. |
| Secrets and authority | Root-only provider credentials and keys stay on Vesta. Customer output exposes necessary DNS instructions and bounded errors, not provider credentials, private keys, internal object IDs, or other tenants. |
| Destructive effects | Disconnect removes only the exact owned connection, route, and provider/certificate objects. Site deletion waits for durable child cleanup; uncertain cleanup retains ownership and recovery records. |

Initial exclusions: wildcard domains, arbitrary customer origins, domain transfers between tenants, automatic DNS-provider login, billing integration, new queue infrastructure, and a provider-plugin framework. Implement one selected provider. Domain reassignment uses completed disconnect followed by fresh proof; a later transfer feature needs its own contract.

## Provider decision: prove the difficult paths first

Cloudflare for SaaS Custom Hostnames is the first candidate because it separates customer DNS from the platform's edge configuration. It is not yet selected. Current documentation creates two material gates:

- Standard onboarding uses a CNAME target. Apex providers with ALIAS/ANAME/flattening may support this; ordinary apex A-record onboarding requires Cloudflare's Apex Proxying capability. Cloudflare lists that as a paid Enterprise add-on. Do not publish ordinary Cloudflare shared edge IPs as a substitute. [Apex proxying](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/advanced-settings/apex-proxying/), [plans](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/).
- Fallback-origin requests use the customer hostname for Host and SNI. Custom-origin configuration has different SNI behavior and documented Full (strict) limitations; SNI rewriting has entitlement and O2O restrictions. A platform wildcard certificate is not assumed sufficient. Prove the actual supported connection and certificate path. [Connection details](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/reference/connection-details/), [custom origins](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/advanced-settings/custom-origin/).

On 2026-09-15, Cloudflare lists 100 included custom hostnames and $0.10 per additional hostname for Free/Pro/Business. Apex and `www` consume separate hostname capacity. Recheck account enrollment, billing period, quotas, required permissions, and any Enterprise/add-on quote before selecting it; base hostname pricing does not establish total product cost. [Cloudflare plans](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/).

If Cloudflare cannot satisfy root-domain coverage and verified origin TLS at acceptable cost, select a Vesta-owned ingress using an established ACME client/service. Prefer the existing native ACME path if it passes the lifecycle gates; add an edge service only if an identified gap requires it. HTTP validation or delegated DNS validation can avoid tenant credentials. The fix must own issuance, installation, renewal, routing, and recovery together. Merely putting the old Let's Encrypt cron back is insufficient. [ACME challenge options](https://letsencrypt.org/docs/challenge-types/).

Milestone 1 must select one implementation and record its exact origin/Host/SNI/certificate design before provider-specific implementation. A failed Cloudflare apex test is a decision input, not acceptance of missing apex support.

## Authority, data, and public contract

| Layer | Durable responsibility |
| --- | --- |
| Vesta native site | Existing `web.conf`, immutable technical hostname, platform DNS record, proxy destination, and native site lifecycle. |
| Vesta connection registry | One authoritative root-owned record per normalized hostname across every user/site on the selected Vesta authority. Stores owner, technical site, connection ID, generation, proof, desired state, provider object references, observed state, and cleanup progress. |
| API tenant database | Site-associated connection request, idempotency key, Vesta connection ID, desired operation, durable delivery/recovery state, and last observed sanitized projection. It cannot assert infrastructure readiness independently. |
| Frontend/store | Typed public contract, DNS instructions, progress, primary-domain selection, and freshness. No independent provider logic. |

Use `data/vx/domain-connections/hostnames/<sha256-of-normalized-hostname>.json` as the proposed Vesta reservation/record location, with the hostname also validated inside the record. Keep it atomic, root-owned, non-symlink, and mode `0600` under mode `0700` directories. User listings are filtered projections. Serialize reservation changes with a short registry lock, and use per-connection revision/lease checks for external work. Do not hold the registry lock while waiting for DNS or provider responses. Reuse existing secure parsing, transport, and persistence helpers where their contracts fit.

This first release has one authoritative Vesta registry for the product. A tenant-local SQL UNIQUE constraint cannot enforce cross-tenant hostname ownership. API replicas and Vesta panel actions must all reach the same Vesta reservation authority. Enabling multiple independent Vesta authorities for this product is outside this release and requires a shared reservation authority first; the hostname invariant cannot be relaxed during scaling or host migration.

Normalize a hostname once: lowercase IDNA ASCII, remove a terminal dot, validate label/total length, and use a maintained public-suffix implementation where apex classification is needed (`.com.au` must work). Reject URLs, paths, ports, IP literals, wildcards, and the platform's reserved technical namespace. Bind fresh random DNS proof to the exact connection, site, and generation. Pending reservations have bounded lifetime and per-tenant quotas. A competing tenant cannot use a stale CNAME, expired proof, or a deleted connection's identifier to claim a hostname.

Public HTTP acceptance probes must target approved ingress and validate resolved IPv4/IPv6 addresses and every redirect. Reject private/link-local destinations and bound timeouts and response sizes; customer-controlled DNS must not become a server-side request proxy. Internal origin checks use fixed operator-owned targets, never a customer-supplied origin URL.

Suggested public state vocabulary, frozen in Milestone 1:

| State | Meaning and next action |
| --- | --- |
| `pending_verification` | Show the connection-specific TXT or supported delegated proof instruction; publish no customer content. |
| `pending_dns` | Ownership proved; routing DNS is absent, conflicting, or still propagating. Show the exact expected records. |
| `pending_tls` | Routing is correct; edge certificate, verified origin, or route acceptance is incomplete. Retry automatically. |
| `connected` | Proof, routing, certificate, origin verification, and correct-site public HTTPS checks passed for this generation. |
| `degraded` | A connected domain has a renewal, routing, or availability problem. Retain ownership; show the reason and last successful observation. |
| `disconnecting` / `disconnected` | Stop serving tenant content for the hostname, clean up exact owned objects, then release the claim. |
| `failed` / `recovery_required` | A terminal input/policy problem or an uncertain external mutation respectively; show a bounded remedy and retain recovery authority where needed. |

Include component observations, `lastCheckedAt`, `lastSuccessfulAt`, `nextCheckAt`, stable error code, connection revision, and public DNS instructions. A cached `connected` result is not a timeless health guarantee. Define retryable versus terminal failures and status transitions in the contract, including expired verification, conflicting AAAA, CAA restrictions, DNSSEC failures, provider rate limits, and certificate expiry.

Proposed new thin Vesta adapters, preserving existing command signatures:

```text
v-add-vx-web-domain-connection USER TECHNICAL_FQDN HOSTNAME REQUEST_ID [json]
v-list-vx-web-domain-connections USER TECHNICAL_FQDN [json]
v-reconcile-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-delete-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-update-vx-web-domain-connections [json]
```

Create persists a reservation and returns pending state promptly; repeated `REQUEST_ID` with the same input is idempotent and different input conflicts. The list command reads persisted state without reconciliation or writes. Explicit reconcile performs one bounded attempt; the worker retries due records through the same helper. A versioned capability response lets API and panel callers reject an incompatible Vesta release before mutation. Use existing authenticated Vesta command authorization; do not grant direct tenant sudo.

Proposed authenticated API routes under the existing `/v{version}/Sites` prefix:

| Method and suffix | Contract |
| --- | --- |
| `POST /{siteGUID}/Domains` | Accept hostname plus idempotency key; durably queue connection and return `202` with its identifier and pending state. |
| `GET /{siteGUID}/Domains` and `GET /{siteGUID}/Domains/{domainGUID}` | Return tenant-owned cached observations and freshness without provider mutation. |
| `POST /{siteGUID}/Domains/{domainGUID}/Check` | Rate-limited request for a fresh bounded reconciliation; DNS waiting stays asynchronous. |
| `PATCH /{siteGUID}/Domains/{domainGUID}` | Permit primary-domain selection only after current connection acceptance; hostname changes create a new connection. |
| `DELETE /{siteGUID}/Domains/{domainGUID}` | Durably request disconnect and return `202` until exact cleanup is confirmed. |

Use named Slim parameters and matching route-registry segments before the CRUD catch-all; verify both authorization and dispatch. Site reads expose `technicalURL`, connection status, and the selected primary domain. `webURL` uses an accepted primary connection or the technical URL. A transient degraded observation must not silently rewrite the chosen canonical hostname or release ownership; the technical preview link remains available and any actual routing failure is shown.

## Milestones

Paths below are relative to the named repository. Paths described as new are implementation deliverables, not files already present. Read each repository's current `AGENTS.md` and matching skills before editing.

### Milestone 1: Demonstrate a supportable customer-domain HTTPS path

**Authority:** Root-domain, tenant-DNS, TLS, and cost boundaries above.
**Depends on:** None; external mutations require a named disposable test zone, ingress, and approved provider scope.
**Owned paths:** New Vesta `.docs/contracts/domain-connections.md`, `.docs/validation/2026-09-15-domain-connection-provider-decision.md`, and `test/domain-connections/run-provider-acceptance.sh`. Host-specific test deployment evidence belongs beside its server record in `vortex-scripts/Servers/`.
**Behavior:** Freeze the lifecycle/capability contract and select one provider after testing two isolated sites against this matrix:

| Scenario | Required evidence |
| --- | --- |
| Ordinary external subdomain | Customer-owned CNAME, connection-specific proof, trusted HTTPS, and expected site content without tenant API credentials. |
| Apex with flattening | Successful apex connection using the authoritative provider's supported record mechanism; `www` checked independently. |
| Apex without flattening | A tested supported A/AAAA ingress path, or a rejected Cloudflare candidate followed by a passing selected alternative. |
| Customer already on Cloudflare | Separately controlled zone; supported proxied and DNS-only configurations documented and tested, including O2O where used. |
| Origin and tenant isolation | Observed Host/SNI and verified origin certificate; wrong-host, forged forwarding header, and cache-isolation tests cannot return another site's content. |
| Renewal and failure | Provider-supported unattended renewal path for both TLS legs; issuance/rotation and failure recovery exercised using staging or controlled expiry. Record when a real scheduled renewal remains unobserved. |
| Default site | Technical URLs keep valid HTTPS and correct content throughout connection attempts. |

**Exclusions:** No production `vxapp.io` changes, tenant-domain changes, Enterprise purchase, or credential expansion follows from this plan. A test account controlled by the operator represents an external customer; its credentials are not given to Vesta.
**Focused proof:** New runner: `bash test/domain-connections/run-provider-acceptance.sh --config-file /run/vx-domain-acceptance/config.json`. It must require a root-only allowlist of the authorized test zone, hostnames, and ingress; default to inspection and require `--apply` for its named test mutations. It must stop before mutations if capability/cost approval is missing, never use `curl -k`, and produce redacted per-scenario evidence. Run the mutation mode only after the test scope is authorized. Public documentation alone does not pass this milestone.

### Milestone 2: Connect and maintain domains safely through Vesta

**Authority:** The Milestone 1 contract, existing Vesta/native proxy authority, and hostname ownership invariants.
**Depends on:** Milestone 1 provider decision. Provider-independent registry work may start against its frozen contract while the live proof is pending; provider activation may not.
**Owned paths:** New `func/vx/domain-connections/` helpers and the five adapters above; narrow hooks in `func/vx/cloudflare/main.sh`, `func/vx/cloudflare/web-hooks.sh`, `func/vx/proxy.sh`, `func/domain.sh`, `func/rebuild.sh`, `bin/v-add-vx-managed-web-domain`, native alias/delete/SSL guards, `bin/v-update-sys-queue`, `bin/v-backup-user`, `bin/v-restore-user`, and `web/api/index.php`. Add new `test/domain-connections/test-state.sh` and `test-provider.sh`; extend relevant existing `test/cloudflare/` suites. Mirror any changed shipped ingress templates in applicable `install/` and `example-of-linux-root-folder/usr/local/vesta/data/templates/web/nginx/` paths.
**Behavior:** Implement durable reservations, bounded reconciliation, verified publication, unattended renewal, degradation, disconnect, and cleanup. Persist intent/object identity before the next irreversible step; recover a provider success followed by local failure through exact readback instead of creating duplicates. Reject stale generation jobs and preserve tombstones until cleanup finishes. Use one due-work scheduler integrated with existing Vesta scheduling, bounded backoff and `Retry-After`; do not keep PHP requests or provider locks open through propagation waits.

Keep technical-site creation alias-free and synchronously ready. New connections use the selected certificate/routing path independently of the old shared alias-SAN rotation. Explicitly guard native alias, rebuild, delete, rename, and manual SSL entry points so they cannot bypass proof or apply the legacy certificate model to a new connection. Unknown/unverified Host values serve no tenant content; ACME challenge handling, if selected, exposes only the required challenge. Preserve the existing Host and authoritative BusinessGUID routing contract and verify it against the trusted upstream. Reuse validated native config testing/reload behavior; failed rendering or certificate installation restores the last accepted served state.

Add one connection-provider configuration independent of `VX_MANAGED_DNS_PROVIDER`, initially disabled. Keep existing platform-zone credentials and technical-site readiness intact. Document precisely the selected provider's required scoped permissions; tenants receive no token field.

Include owned connection authority in existing backup/export and restore paths with appropriate protection for private material. Restore must check current reservations and provider ownership before activating routes; missing/corrupt authority fails closed. Preserve the single-authority boundary during host recovery. Expose worker heartbeat, overdue attempts, certificate-expiry warnings, and terminal cleanup failures through existing operator status/logging and monitoring surfaces.

**Exclusions:** No broad native-command rewrite, no second provider implementation, no assumption that provider `active` alone means correct public content, and no customer DNS writes.
**Focused proof:** `bash test/domain-connections/test-state.sh`; `bash test/domain-connections/test-provider.sh`; `bash test/cloudflare/test-cloudflare-managed-domains.sh`; `bash test/cloudflare/test-cloudflare-native-lifecycle.sh`; `bash test/test_web_domain_proxy.sh`. Cover cross-user simultaneous claims, normalization, stale proof/jobs, process interruption at external/local boundaries, 429/timeouts, key secrecy, renewal failure, DNS drift, unsafe probe destinations, wrong origin, exact deletion, rebuild, restore collisions, and unchanged technical HTTPS. Run `bash -n` on touched Bash and `php -l web/api/index.php`.

### Milestone 3: Offer durable tenant-domain operations through the API

**Authority:** Milestone 1 public contract and the API's tenant, route, migration, and Vesta boundaries.
**Depends on:** Milestone 2 capability/CLI contract; repository-local work can use contract fixtures until integrated Vesta is ready.
**Owned paths:** In `api-vxapp`, new `api/src/vortex/ServicesV2/Sites/Domains/` for persistence, intent processing, and projections; a new direct entry in `api/src/vortex/ServicesV2/Sites/Migrations/`; existing `Database/SitesCreateTables.php`, `Operations/SiteOperations.php`, `Operations/SiteOperationsFactory.php`, `Enums/SiteField.php`, `Enums/SiteProjectionField.php`, `Validators/SiteFieldValidator.php`, `Formatters/SitesResponseFormatter.php`, and `Inspection/VestaSiteInspector.php` beneath `ServicesV2/Sites/`. Extend `api/src/vortex/Vesta/Sites/`, `api/src/vortex/Vesta/Enums/VestaApiCommand.php`, `api/src/vortex/Routes/SitesRoutes.php`, `api/src/vortex/Routes/DataProviders/SitesRoutes.json`, and the appropriate `api/src/vortex/Cron/Handlers/` registration. New focused tests live in `api/src/tests/ServicesV2/Sites/Domains/` and `api/src/tests/Integration/ServicesV2/Sites/Domains/`.
**Behavior:** Implement the routes above with owner-scoped lookup, explicit capability checks, durable request/idempotency state, and leased retries. Return pending promptly after committing the request; failures before Vesta submission and after Vesta success are recoverable. Vesta's registry decides hostname ownership; tenant-local rows are requests/projections. Reuse the existing outbox pattern from `ServicesV2/Orders/Events/`, without reusing its table or semantics. The existing `Sites/RuntimeRefresh/` queue remains solely for slave runtime delivery; notify it after relevant accepted connection/primary changes.

Choose primary atomically within the site. Update `webURL` selection and provide `technicalURL` while connection is pending. Preserve the current create ordering and trusted proxy configuration. Replace legacy alias-field editing through an explicit versioned compatibility transition: existing clients receive the documented legacy result or a clear unsupported-operation error, never an undocumented pending success. Preserve old alias fields as read projections during migration; remove writes only with the compatible client release. Site delete marks intent before external cleanup, prevents older queued work from recreating connections, and retains a recoverable record until Vesta confirms cleanup.

**Exclusions:** No Cloudflare SDK in the API, no generic Domain service replacing unrelated subsystems, no global uniqueness claim based on tenant tables, and no new queue service. Do not rewrite an applied migration; follow `MIGRATIONS.md`.
**Focused proof:** New suites: `composer test:file -- api/src/tests/ServicesV2/Sites/Domains` and `composer test:file -- api/src/tests/Integration/ServicesV2/Sites/Domains`. Existing regression selectors: `composer test:file -- api/src/tests/Vesta/Sites/VestaManagedSiteLifecycleTest.php`, `composer test:file -- api/src/tests/ServicesV2/Sites/SiteOperationsTest.php`, `composer test:file -- api/src/tests/ServicesV2/Sites/SitesResponseFormatterTest.php`, and `composer test:file -- api/src/tests/ServicesV2/Sites/SitesRoutesRegistrationTest.php`. Include DB failure, concurrent requests, lost Vesta response, retry/restart, owner mismatch, stale observations, primary races, and interrupted deletion. Run `./validate.sh --changed`, `composer analyse:changed`, and `composer migrations:list -- --json`; migration mutation tests use isolated test databases only.

### Milestone 4: Let customers connect, inspect, and remove domains

**Authority:** The lifecycle contract and customer-control boundary.
**Depends on:** Milestone 3 route and response contract; UI implementation can use typed fixtures while API integration completes.
**Owned paths:** In `vue-vxapp-team-ci` (the `vue-vxapp` repository), `src/components/Forms/Sites/SiteIdentityInputs.vue`, `siteFormData.ts` in that directory, `src/views/apps/sites/SiteSummaryCard.vue`, `SiteConfigurationCard.vue`, `SiteFormPage.vue`, `SitePreviewPage.vue`, and `src/components/ServiceLists/Sites/siteListPresentation.ts`. Add a domain-connection component beside the existing site cards only as needed. Shared store changes belong in `stores-vxapp` through `src/@vxapp/Sites/useSiteStore.ts`; generate API enums/contracts from their source instead of editing generated consumers. In Vesta, update `web/add/vx-cloudflare-domain/index.php`, `web/templates/admin/add_vx_cloudflare_domain.html`, and the relevant edit/list links and status presentation.
**Behavior:** Replace raw alias editing with “Connect domain”: hostname entry, copyable ownership/routing records, automatic progress updates, a rate-limited check action, actionable errors, last-checked time, primary selection, and disconnect. Explain apex and `www` separately. Always show the technical preview URL. Keep site creation usable when no customer domain is connected. Vesta's existing admin surface uses the same connection helpers and statuses; preserve admin-only scope there, CSRF, shell escaping, and owner-scoped reads. Do not introduce a separate alias bypass in either UI.

Publish typed store/contracts and compatible API/UI versions together. Future implementation of this milestone explicitly includes the necessary `stores-vxapp` changes and consumer pointers, subject to its own repository instructions. This planning turn does not edit those submodules.

**Exclusions:** No customer provider-token input, no general DNS editor, no implementation jargon or provider object IDs in customer flows, and no blocking browser request while certificates provision.
**Focused proof:** `pnpm exec vitest --run src/components/Forms/Sites/__tests__/SiteIdentityInputs.spec.ts src/components/Forms/Sites/__tests__/siteFormData.spec.ts src/views/apps/sites/__tests__/SiteSummaryCard.spec.ts src/views/apps/sites/__tests__/SiteFormPage.spec.ts src/@vxapp/Sites/__tests__/useSiteStore.spec.ts`; `pnpm run type-check`; `pnpm run validate`; `bash tools/e2e/runManagedLocalPlaywright.sh e2e/sites/sites-crud.spec.ts --project=chromium`. Add selectors for a new component only if created. Extend the browser scenario through pending DNS, ready, primary, degraded, retry, and disconnect with two tenants. In Vesta run `php test/test_cloudflare_web_ui.php` and lint changed PHP/JavaScript files. Pending states must remain usable and accessible.

### Milestone 5: Adopt existing sites without breaking their current domains

**Authority:** Existing lifecycle protection and the read-only SydVortex migration findings.
**Depends on:** Milestones 2 and 3; may proceed alongside Milestone 4 after their contracts stabilize.
**Owned paths:** New versioned migration entry points under `install/migrations/domain-connections/`, shared logic in `func/vx/domain-connections/`, and new `test/domain-connections/test-migration.sh`. Existing `func/vx/cloudflare/migration.sh` and `install/migrations/cloudflare-managed-web-domains/` remain legacy authority; make only necessary compatibility/error-reporting changes, retaining their tests. Product instructions belong in a new `.docs/user-guides/domain-connections.md`; any eventual SydVortex rollout plan/evidence belongs in `vortex-scripts/Servers/SydVortex/Plans/` and `Reports/`.
**Behavior:** Provide read-only assessment, explicit preparation, revision-bound apply, and bounded rollback for both native legacy sites and existing Cloudflare-managed sites. Assessment must perform no local or provider writes. Inventory exact primary/aliases, TLS authority, certificate expiry, proxy destination, Host/BusinessGUID configuration, and affected routes; retain current customer service until replacement acceptance. Importing a database alias is not proof of domain ownership or HTTPS readiness.

Allocate/adopt the technical identity without renaming a live customer site ahead of a prepared route/certificate transition. Establish the new connection's proof and TLS path, validate configuration, then cut over the exact site. Preserve the old certificate and routing authority for rollback until the retention gate passes. Keep cleanup idempotent and retain exact references after partial failure. Do not remove Let's Encrypt renewal from a legacy site before a tested successor owns its certificate lifecycle. Do not expand the old token-accessibility precondition into a false proof that a SaaS connection is ready.

The eventual production candidate is Vesta user `Jack9f6fa`, with `castlesoncommand.com.au`, `nextgenerationhoardings.com.au`, and `newcastleslushiehire.com.au`, including their `www` aliases. These are future migration targets, not disposable tests. Reinspect their then-current state; migrate one site first and accept both apex and `www` before the remaining two. Preview must disclose shared Nginx/Apache reload or restart effects. Preserve the native proxy target and routing metadata exactly unless separately authorized.

**Exclusions:** No execution of the current blocked migration, no automatic rollback that overwrites later user changes, no DNS/nameserver changes, and no retirement of unrelated workload rollback resources. Production apply requires exact release and target authorization.
**Focused proof:** `bash test/domain-connections/test-migration.sh`; `bash test/cloudflare/test-cloudflare-managed-web-domain-migration.sh`; `bash test/cloudflare/test-cloudflare-native-migration-ssl-capability.sh`; `bash test/cloudflare/test-cloudflare-native-migration-rebuild-capability.sh`. Exercise unchanged assessment hashes, prepare/apply replay, conflicting ownership, SAN/route transitions, shared-service failure, interrupted cutover, partial cleanup, and rollback with drift refusal. Fixtures cover all three target site shapes; live acceptance waits for separate authorization.

### Milestone 6: Accept the integrated product and prepare a controlled release

**Authority:** All preceding acceptance boundaries, repository release gates, and the current Vesta deployment authority.
**Depends on:** Milestones 1–5. This is the comprehensive integration/review checkpoint.
**Owned paths:** Vesta `.docs/contracts/domain-connections.md`, `.docs/user-guides/domain-connections.md`, `.docs/user-guides/vesta-cloudflare-managed-dns.md`, `.docs/README.md`, and release evidence under `.docs/validation/`; API route/technical documentation and `MIGRATIONS.md`; generated shared contracts and frontend behavior documentation where affected. Machine state, operational configuration, deployment evidence, and rollback records remain in `vortex-scripts/Servers/`.
**Behavior:** Accept the whole create → technical preview → connect apex/`www` → prove ownership → obtain HTTPS → choose primary → renew/recover → disconnect → delete journey on two authorized test tenants. Test provider outage, service restart, stale job, DNS removal, and certificate failure. Prove no tenant tokens, no cross-tenant claim/content leakage, no premature success, and no loss of the technical URL. Reconcile old guide statements by explicit lifecycle version, leaving legacy instructions accurate for unmigrated sites.

Publish a compatible release set: Vesta capability first, additive API schema/contracts and worker next, store/UI consumers next, then feature activation. Keep connection creation disabled until all required versions and the renewal worker are verified. Disabling new enrollment must not stop renewal or disconnect recovery for existing connections. Provide rollback compatibility for active new connections; do not downgrade to a release that cannot read their authority. Obtain production authorization only after exact releases, target scope, expected shared-service effects, and recovery material are concrete and reviewable.

**Exclusions:** Passing local tests is not production deployment; a staging certificate rotation is not evidence that months of unattended production renewal have occurred. Preserve this distinction in release claims.
**Focused proof:** Run all focused domain suites once against the final revisions, then Vesta `bash test/compose/run-production-readiness-limited.sh`. In the authorized API test environment run `bash scripts/run-e2e.sh -- vendor/bin/phpunit --no-coverage --fail-on-skipped api/src/tests/E2E/SitesE2ETest.php` plus the new domain lifecycle E2E selector added to that suite. Run the Milestone 4 managed browser journey against the same compatible contracts and the Milestone 1 provider matrix against the selected implementation. Record revisions and redacted results; run `git diff --check`, validate links, review the integrated changes, and commit only task-owned files. Follow submodule commit/push and parent-pointer rules where applicable.

## Execution ledger, dependencies, and handoff

Use `$milestone-driven-implementation` as the sole execution coordinator when implementation is authorized. Create/link one successor owner issue in `jackpridham/vesta-vxapp` for this plan before GitHub-backed execution; record milestone state, accepted revisions, evidence, and the numbered blockers below there. This planning request does not publish an issue or comment. Do not create a separate ledger or review loop per repository or subtask.

[Vesta #5](https://github.com/jackpridham/vesta-vxapp/issues/5) records the completed original Cloudflare behavior. [Vesta #6](https://github.com/jackpridham/vesta-vxapp/issues/6) covers admin Cloudflare configuration and general DNS control; it is not the owner or prerequisite for customer-domain connection. Coordinate overlapping helpers before implementing either scope. Reconcile the existing API [#139](https://github.com/jackpridham/api-vxapp/issues/139) lifecycle work and [#141](https://github.com/jackpridham/api-vxapp/issues/141), [#142](https://github.com/jackpridham/api-vxapp/issues/142), [#143](https://github.com/jackpridham/api-vxapp/issues/143), [#144](https://github.com/jackpridham/api-vxapp/issues/144), [#145](https://github.com/jackpridham/api-vxapp/issues/145), [#146](https://github.com/jackpridham/api-vxapp/issues/146), and [#227](https://github.com/jackpridham/api-vxapp/issues/227) against the new contract when issue updates are authorized. Preserve completed migration history in [#140](https://github.com/jackpridham/api-vxapp/issues/140). Do not claim those issues already implement this proposal.

| Milestone | Initial state | May run alongside |
| --- | --- | --- |
| 1. Provider feasibility and contract | Planned; live proof not authorized or run by this plan | Local contract/registry design |
| 2. Vesta connection lifecycle | Planned | API implementation against frozen fixtures |
| 3. Durable API operations | Planned | Vesta provider work and typed UI fixtures |
| 4. Customer workflow | Planned | Existing-site migration implementation |
| 5. Existing-site adoption | Planned | Customer UI after Vesta/API contracts stabilize |
| 6. Integrated release acceptance | Planned | No competing broad closeout gate |

One numbered blocker list for execution:

1. **Provider suitability:** actual apex coverage and required commercial entitlements are unproven. Resolve in Milestone 1 before selecting the provider.
2. **Verified TLS and renewal:** prove Host/SNI/certificate behavior, O2O compatibility where used, and unattended renewal on both TLS legs. Resolve in Milestone 1; failures remain release blockers.
3. **Authorized test resources:** name disposable domains, test ingress, allowed external mutations, and any permitted spend before live provider proof. Offline work can proceed independently.
4. **Contract/release coordination:** freeze the capability and public contracts, reconcile overlapping issue scope, and identify the compatible API/store/UI/Vesta release set. Resolve before activation.
5. **Production adoption:** fresh state inspection, exact release/target authorization, and verified recovery material are outstanding for the three `Jack9f6fa` sites. Resolve only at the controlled rollout gate; this does not block completing the development plan.

Requirements trace: permanent site identity → Milestones 2–3; customer-owned DNS and apex HTTPS → 1–2; proof, reservation, and isolation → 1–3; resumable progress and primary selection → 2–4; renewal, degradation, and cleanup → 2–3 and 6; existing-site continuity → 5–6; costs, compatibility, and operational handoff → 1 and 6.
