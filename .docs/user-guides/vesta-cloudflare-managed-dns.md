# Vesta-Managed Cloudflare DNS

Vesta can allocate a public technical hostname for each new panel website and
own that hostname's Cloudflare A-record lifecycle. The first release is
deliberately narrow: one Cloudflare zone, one proxied A record per managed
website, Cloudflare Auto TTL, and exact-record deletion.

## Ownership model

- The panel never accepts a primary website domain. Vesta generates
  `s-<10 lowercase hexadecimal characters>.<configured-zone>` internally.
- Optional customer domains are stored as ordinary Vesta web aliases. They do
  not replace or rename the technical hostname.
- The **Add Cloudflare Domain** action in the DNS area attaches a domain that
  is already configured in its authoritative DNS to an existing Vesta
  website. It does not edit that custom domain's DNS.
- Only the generated technical hostname is created, reconciled, and deleted
  through the configured Cloudflare zone.
- The installed local DNS service remains recorded in `DNS_SYSTEM`.
  `VX_MANAGED_DNS_PROVIDER` independently selects whether Vortex-managed web
  hostnames use Cloudflare.

Cloudflare documents bearer API tokens as its preferred authentication method.
The scoped token for this integration must be restricted to the one managed
zone with Zone Read and DNS Read/Edit permissions. The integration uses the
zone-details and DNS-record endpoints documented in the
[Cloudflare API](https://developers.cloudflare.com/api/resources/dns/subresources/records/).

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
the zone ID and account email. It validates access to the exact zone
before atomically replacing the existing configuration. A failed validation
does not replace working credentials.

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

Status output is value-free. It reports stable states such as `ready`,
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
and returns the generated public hostname.

Existing automation that already owns a Vesta technical domain can request an
idempotent reconciliation without choosing provider values:

```bash
sudo /usr/local/vesta/bin/v-reconcile-vx-cloudflare-web-domain USER DOMAIN
```

Normal `v-delete-web-domain USER DOMAIN` detects managed technical hostnames.
It verifies and deletes the exact record identity saved for that domain before
removing Vesta state. An absent record is an idempotent success. A provider or
ownership verification failure stops deletion so Vesta does not knowingly
orphan the managed record. No zone-wide search or broad deletion occurs.

## Recovery and rotation

- Retry `v-reconcile-vx-cloudflare-web-domain USER DOMAIN` after a transient
  transport, timeout, or rate-limit failure. Read-before-write and readback
  make retries convergent.
- Duplicate/conflicting records fail closed. Resolve the unexpected records in
  Cloudflare, then retry; do not remove Vesta ownership metadata manually.
- Rotate credentials by running `v-configure-vx-cloudflare` again. The new
  candidate is validated before it replaces the current configuration.
- If a managed website cannot be deleted, restore provider access and retry
  the same Vesta delete command. Do not delete the Vesta data directory or
  metadata file directly.

## First live acceptance

After nonsecret code deployment, the protected acceptance sequence is:

1. Configure the scoped token and exact zone.
2. Select **Cloudflare managed** and require health `ready`.
3. Create one disposable panel website with a custom alias omitted.
4. Verify the returned hostname's Cloudflare A record and public resolution to
   the intended Vesta ingress.
5. Delete the website and verify the exact record is absent.

Acceptance evidence must record only stable statuses and pass/fail results;
never include protected provider values or raw responses.
