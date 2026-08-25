# Vesta-Managed Cloudflare DNS

Vesta can allocate a public technical hostname for each new panel website and
own that hostname's Cloudflare A-record lifecycle. Each managed website also
receives a Cloudflare Origin CA certificate for its technical hostname and
complete Vesta alias set, so Cloudflare Full (strict) works from first create.
The release remains deliberately narrow: one configured Cloudflare zone, one
proxied A record per managed website, Cloudflare Auto TTL, and exact record and
certificate deletion.

## Ownership model

- The panel never accepts a primary website domain. Vesta generates
  `s-<10 lowercase hexadecimal characters>.<configured-zone>` internally.
- Optional customer domains are stored as ordinary Vesta web aliases. They do
  not replace or rename the technical hostname.
- The **Add Cloudflare Domain** action in the DNS area attaches a domain that
  is already configured in its authoritative DNS to an existing Vesta
  website. It does not edit that custom domain's DNS, but it verifies the
  exact record, proxy state, edge-certificate coverage, and zone TLS mode
  before accepting the alias.
- Only the generated technical hostname is created, reconciled, and deleted
  through the configured Cloudflare zone.
- Certificate private keys and CSRs are generated on the Vesta host. Cloudflare
  returns only the signed Origin CA certificate; the private key never leaves
  Vesta. Alias add/remove rotates the per-site certificate to the complete
  current hostname set.
- The installed local DNS service remains recorded in `DNS_SYSTEM`.
  `VX_MANAGED_DNS_PROVIDER` independently selects whether Vortex-managed web
  hostnames use Cloudflare.

Cloudflare documents bearer API tokens as its preferred authentication method.
The token needs Zone Read, Zone Settings Read/Write, DNS Read/Edit, and SSL and
Certificates Read/Edit for the configured zone and for every custom-alias zone
it will certify. The
integration uses the documented
[DNS record API](https://developers.cloudflare.com/api/resources/dns/subresources/records/)
and [Origin CA API](https://developers.cloudflare.com/api/resources/origin_ca_certificates/).
Custom aliases must already belong to zones accessible to this token and have
an exact proxied `A` record pointing to the website's Vesta/NAT ingress address
or a proxied `CNAME` pointing to its generated technical hostname. An active
edge certificate must cover the exact alias. Otherwise the alias operation
rolls back without publishing a Full (strict)-broken hostname. Vesta enforces
and reads back `strict` mode for the configured and alias zones; because this
is a zone-wide Cloudflare setting, every other origin in those zones must also
serve a valid certificate.

## Configure credentials

Configuration requires root and is stored at
`/usr/local/vesta/data/vx/cloudflare/config.conf` beneath mode-`0700`
directories as a root-owned mode-`0600` file. Protected values are never
command arguments.

Interactive setup:

```bash
sudo /usr/local/vesta/bin/v-configure-vx-cloudflare
```

The command requests the API token with terminal echo disabled, then requests
the zone ID and account email. It validates access to the exact zone and the
Origin CA service, enforces and reads back Full (strict), and requires active
edge-certificate coverage for generated first-level hostnames before atomically
replacing the existing configuration. A failed validation does not replace
working credentials. A different zone cannot replace the configured zone while
managed record or certificate metadata still exists; same-zone token rotation
is supported.

For automation, place the three exact assignments in a regular, root-owned
mode-`0600` file and pass only its path:

```text
API_TOKEN='replace-with-token'
ZONE_ID='32-lowercase-hex-characters'
ACCOUNT_EMAIL='operator@example.com'
```

```bash
sudo /usr/local/vesta/bin/v-configure-vx-cloudflare \
  --config-file /run/secrets/vesta-cloudflare-input
```

Delete the input file immediately after configuration. Do not provide a token,
zone ID, email, record ID, or ingress address on a command line or through an
environment variable.

## Select Cloudflare-managed mode

After credentials validate, open **Server → Configure → DNS**, select
**Cloudflare managed**, and save. The equivalent CLI is:

```bash
sudo /usr/local/vesta/bin/v-change-vx-dns-provider cloudflare-managed
```

Return managed web creation to local/non-Cloudflare mode without changing the
installed DNS service:

```bash
sudo /usr/local/vesta/bin/v-change-vx-dns-provider local
```

## Health and preflight

Human output:

```bash
sudo /usr/local/vesta/bin/v-list-vx-cloudflare-status
```

Machine output:

```bash
sudo /usr/local/vesta/bin/v-list-vx-cloudflare-status json
```

Status output is value-free. `ready` requires exact zone access, Origin CA
read access, Full (strict) readback, and active edge-certificate coverage for
generated hostnames. It reports stable states such as `ready`,
`not_configured`, `provider_disabled`, `unauthorized`, `rate_limited`,
`timeout`, and `malformed_response`; it never prints the configured zone,
address, credential, record identity, or raw Cloudflare response.

## Website lifecycle

The panel uses this Vortex-owned creation surface:

```text
v-add-vx-managed-web-domain USER [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS] [proxy options]
```

There is intentionally no `DOMAIN` argument. The command validates Vesta and
provider prerequisites, generates a collision-resistant label, creates the
native Vesta web domain with custom domains as aliases, reconciles exactly one
proxied A record to the web domain's Vesta/NAT address, reads the record back,
issues and installs a 15-year per-site Origin CA certificate for the generated
hostname and aliases, and returns the generated public hostname. If DNS or
certificate setup fails, the new website, exact provider record, and any issued
certificate are compensated automatically.

Adding or removing a Vesta web alias automatically validates its Cloudflare
zone/DNS/proxy/edge/strict prerequisites and rotates that site's Origin CA
certificate before the final web/proxy restart. The previous certificate is
revoked only after the replacement is installed and its exact ID remains
durable until revocation is confirmed. An issuance or installation failure
restores the previous alias and certificate state. Manual certificate,
Let's Encrypt, and SSL removal commands are refused for managed sites.

Native alias and website-delete commands also fail closed when either managed
record or certificate metadata path exists but the complete exact authority
pair cannot be validated. This includes partial, malformed, symlinked,
mismatched-zone, and otherwise degraded metadata. Native website state is not
changed in that condition. During deletion, Vesta retains enough exact record
and certificate authority for a bounded retry until both owned Cloudflare
objects are confirmed absent; custom-domain DNS remains untouched.

Changing a managed website's Vesta IP automatically reconciles its exact
Cloudflare A record. If provider reconciliation fails, the native IP and
provider state are compensated to the previous value rather than reporting a
successful stale change. Product panel and authenticated API creation use the
managed allocator. Authenticated API creation is rejected before native
mutation unless the provider is exactly `cloudflare-managed`; it never falls
through to a caller-supplied primary domain. Low-level native create commands
remain compatible for root-owned restore/import workflows.

Existing automation that already owns a Vesta technical domain can request an
idempotent reconciliation without choosing provider values:

```bash
sudo /usr/local/vesta/bin/v-reconcile-vx-cloudflare-web-domain USER DOMAIN
```

Normal `v-delete-web-domain USER DOMAIN` detects managed technical hostnames.
It verifies and revokes the exact Origin CA certificate and deletes the exact
record identity saved for that domain before removing Vesta state. An absent
provider object is an idempotent success. A provider or ownership verification
failure stops deletion so Vesta does not knowingly orphan managed state. No
zone-wide search or broad deletion occurs.

Certificate reconciliation is available for recovery without passing any key,
hostname set, certificate ID, or provider value:

```bash
sudo /usr/local/vesta/bin/v-reconcile-vx-cloudflare-origin-ssl USER DOMAIN
```

## Migrate existing websites

Existing native Vesta websites are migrated only through the explicit operator
migration in `install/migrations/cloudflare-managed-web-domains/`. Packaging,
`postinst`, RPM installation, and ordinary Vesta updates never invoke it. Run
it only after Cloudflare-managed mode is selected and
`v-list-vx-cloudflare-status` prints exactly `ready`.

Choose a bounded plan name and prepare a protected inventory. Preparation
performs provider GET/readback checks and writes a root-only plan, but does not
change Vesta website authority, rendered configuration, services, DNS records,
or certificates:

```bash
sudo /usr/local/vesta/install/migrations/cloudflare-managed-web-domains/prepare.sh \
  legacy-web-20260825
```

For a staged run, add one Vesta user filter. The default always inventories
every configured website, including suspended users and domains:

```bash
sudo /usr/local/vesta/install/migrations/cloudflare-managed-web-domains/prepare.sh \
  legacy-web-20260825-alice --user alice
```

The immutable plan, exact pre-migration snapshots, results, recovery journal,
and mapping handoff are stored below
`/usr/local/vesta/data/vx/cloudflare/migrations/<plan-name>/`. The directory is
root-owned mode `0700`; protected files are regular, non-symlink mode `0600`
files. Human and JSON command output contains counts and bounded states only.
The protected `mapping.json` is the downstream issue #140 handoff and must not be
copied into tickets, logs, or ordinary command output.

The plan also carries a protected, plan-bound rollback-admission artifact. It
fingerprints each scoped user's complete authoritative `web.conf` and rendered
web configuration tree, including websites that the plan classifies and skips.
The fingerprints are refreshed only after a stable migration or compensation
state. This prevents rollback or an idempotent apply from replacing unrelated
domain rows, template/proxy changes, or rendered-file changes made after the
last admitted state.

After a root operator has reviewed and approved that exact plan, apply it:

```bash
sudo /usr/local/vesta/install/migrations/cloudflare-managed-web-domains/apply.sh \
  legacy-web-20260825
```

Apply rejects configuration, inventory, alias-routing, filesystem, or plan
drift before mutation. Each website is a separate transaction: the existing
primary becomes an alias, prior aliases remain, and a newly allocated
`s-<10 hex>.<zone>` hostname becomes the immutable primary without creating a
new document tree. Vesta then creates only that technical hostname's proxied A
record, installs the exact Origin CA certificate, rebuilds once, and verifies
the complete managed state, including the authoritative row and rendered web,
proxy, statistics, and backend files. Custom-domain DNS is read and validated
but never created, edited, or deleted.

To reverse that exact plan, use the explicit plan-bound rollback:

```bash
sudo /usr/local/vesta/install/migrations/cloudflare-managed-web-domains/rollback.sh \
  legacy-web-20260825
```

Rollback restores the snapshotted primary, aliases, SSL and rendered material,
proxy/native state, counters, suspension, FTP relationships, and filesystem
identity. It removes only the exact migration-owned technical A record and
Origin CA certificate authority. Access, error, and bandwidth logs retain the
same protected filesystem identity while their normal runtime content may
continue growing during apply and rollback. Repeated apply and rollback calls
are idempotent. A site that cannot be proven restored remains in protected
`recovery_required` state; retain the migration directory and resolve that
state before deleting or replacing the artifact.

Do not change scoped Vesta user-account, authoritative website, or rendered web
state between apply and rollback. Rollback validates every unrelated
`user.conf` value, the entire scoped `web.conf`, the complete rendered tree,
and the exact migration-owned `U_WEB_SSL` and `U_WEB_ALIASES` deltas before it
mutates provider or native state. Unexpected row, `TPL`/`PROXY`, rendered-file,
counter, or ownership changes fail closed as `drift`; the operator's live
change remains byte-for-byte intact. External custom-domain edge health is not
required to undo a plan, but the configured provider must remain in
Cloudflare-managed mode with enough API access to verify and remove the exact
migration-owned record and Origin certificate.

## Recovery and rotation

- Retry `v-reconcile-vx-cloudflare-web-domain USER DOMAIN` after a transient
  transport, timeout, or rate-limit failure. Read-before-write and readback
  make retries convergent.
- Retry `v-reconcile-vx-cloudflare-origin-ssl USER DOMAIN` if certificate
  issuance or installation was interrupted. Vesta derives the exact SAN set
  from its primary-domain and alias authority.
- Duplicate/conflicting records fail closed. Resolve the unexpected records in
  Cloudflare, then retry; do not remove Vesta ownership metadata manually.
- Rotate credentials by running `v-configure-vx-cloudflare` again. The new
  candidate is validated before it replaces the current configuration.
- If a managed website cannot be deleted, restore provider access and retry
  the same Vesta delete command. Do not delete the Vesta data directory or
  metadata file directly.

## Validated development acceptance

Protected live acceptance completed on the approved development host. Bounded
evidence recorded three disposable sites, two
aliases, six successful HTTPS checks, two migrations, two normal deletions,
and exact provider cleanup. It proved generated-host and alias HTTPS through
Cloudflare Full (strict), migration apply and rollback, and deletion of only
Vesta-owned record/certificate authority. All five focused Cloudflare suites,
the panel/proxy regressions, syntax checks, diff checks, and the repository's
limited production-readiness launcher passed. No credential, provider ID,
protected mapping, private key, or raw response was included in the evidence.

This is `vesta-vxapp` owner-repository development acceptance. It is not a
production deployment, and it does not close the separate downstream API work in
issues #139, #140, #142, #145, or #227.

For a future authorized environment, repeat this protected sequence after
nonsecret code deployment:

1. Configure the scoped token and exact zone.
2. Select **Cloudflare managed** and require health `ready`.
3. Create one disposable panel website with a custom alias omitted.
4. Verify the returned hostname's Cloudflare A record, public resolution, and
   HTTPS response through Cloudflare Full (strict), with no 526 response.
5. Attach an already-configured proxied alias whose zone is accessible to the
   token; verify strict readback, its certificate SAN, and HTTPS response.
6. Change the disposable site's Vesta IP and verify the exact Cloudflare A
   record follows it, then restore the original IP.
7. Delete the website and verify the exact record is absent and the exact
   Origin CA certificate is revoked.

Acceptance evidence must record only stable statuses and pass/fail results;
never include protected provider values or raw responses.
