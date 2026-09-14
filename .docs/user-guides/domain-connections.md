# Domain connections, lifecycle version 1

Customer domains retain their DNS provider. Each hostname has a native Vesta vhost and its own public Let's Encrypt lifecycle. The permanent technical hostname remains independently managed by Cloudflare and Origin CA. Apex and `www` are separate connections; both must pass acceptance before both are advertised.

Customers copy their connection-specific TXT proof and the displayed routing records. A subdomain normally uses a CNAME to the shared DNS-only connection target; an apex uses the published ingress A address. The technical preview URL is proxied and is not the customer CNAME target. Connections progress through verification, DNS and TLS checks. DNS changes can take time; a successful create response reserves the name and does not mean HTTPS is ready.

## Operator adoption

The migration tool supports existing native customer primaries with valid public LE certificates, and existing managed technical primaries whose customer aliases have a valid served Origin CA SAN certificate. It preserves the complete native `vx-proxy` binding. It never edits customer DNS. Existing CDN/proxy configurations may require a separate DNS cutover; public ingress acceptance and customer DNS acceptance are independent.

Run these commands as root from `/usr/local/vesta`. `NATIVE_PRIMARY` means the current native row: the customer apex for native adoption, or the existing technical hostname when splitting managed aliases.

```bash
bash install/migrations/domain-connections/assess.sh USER NATIVE_PRIMARY
bash install/migrations/domain-connections/prepare.sh USER NATIVE_PRIMARY
bash install/migrations/domain-connections/apply.sh USER NATIVE_PRIMARY PREPARED_REVISION
bash install/migrations/domain-connections/status.sh USER NATIVE_PRIMARY
```

Assessment is write-free. It inventories aliases, native authority, DNS A/AAAA/CNAME/CAA answers, certificate issuer and expiry, LE enrollment, binding revision, quota and service effects. DNS answers alone are not proof of ownership or HTTPS. Preparation validates exclusive ownership, available native-row/connection quota, matching private key, certificate SANs and at least one day of validity; native LE adoption also requires a trusted certificate chain. It stores private certificate/configuration recovery archives, native counters, and shared web-service include lists in a root-only migration directory. Use the revision returned by **prepare** for apply.

For native adoption, apply allocates a new managed technical parent separately and retains the original customer row, certificate and LE enrollment. Existing aliases become independent child rows without creating additional application sites. Each technical/native row consumes the existing Vesta quota; migrating an apex plus `www` from one native row requires two additional rows.

For managed aliases, apply first reserves the exact names. It removes their old alias authority and prepares their native rows, copied served certificates and identical routing binding without requesting a service restart between those operations. The old running configuration remains available until the whole batch passes configuration validation. The accepted cutover has one vhost per hostname. A copied old Origin CA certificate preserves the existing proxied HTTPS route while native LE installs a public replacement. Initial issuance and replacement failures restore the previous certificate/configuration; failed shared restart invokes recovery. The fixture suite verifies apex and `www` continue to map to the same site.

After public certificate and ingress identity acceptance, imported records are `degraded` with `migration_dns_cutover_check` until the ordinary worker accepts their customer DNS. No old Origin CA SAN is retired during this stage. For managed aliases, after **every** child is `connected`, use the current `expectedRevision` from status to retire the old SAN authority explicitly:

```bash
bash install/migrations/domain-connections/finalize.sh USER NATIVE_PRIMARY EXPECTED_REVISION
```

Finalization checks public TLS/configuration identity again before the normal Origin CA reconciliation. It records the retirement boundary before invoking the provider because that operation can revoke the old certificate. Partial cleanup or a lost provider response remains `recovery_required`; do not restore a potentially revoked certificate. Retry finalize against its current recovery revision to continue forward through the existing provider reconciliation.

Before that retirement boundary, rollback uses the current `expectedRevision` from status:

```bash
bash install/migrations/domain-connections/rollback.sh USER NATIVE_PRIMARY EXPECTED_REVISION
```

Rollback refuses later changes to ownership, generations, quota, bindings, certificates, provider configuration, native rows or rendered/shared configurations. Ordinary observation timestamps and DNS-state progress do not invalidate the ownership revision. Recovery restores the native rows, certificate trees, rendered configurations and service include lists, and reconciles the IP counter. Failed provider cleanup retains a retryable recovery revision. Newly created content directories are retained; the tool does not erase site content. Replaying an applied revision cannot allocate a second technical identity. An interrupted operation with an unrecorded allocation identity or unaccepted mutation requires read-only operator recovery rather than guessing an identity or overwriting drift. After Origin CA retirement, use forward repair; automatic rollback is refused.

The shared web/proxy services restart at accepted cutover and may restart again during certificate installation or recovery. Preparation currently rejects arbitrary web-config change triggers and PHP configurations using per-domain pools: those native side effects require additional prepared backend recovery. Shared user pools, or configurations without a PHP backend, are supported. Host-specific triggers/listeners/firewalls and live acceptance remain separate rollout work.

The three named `Jack9f6fa` production sites (`castlesoncommand.com.au`, `nextgenerationhoardings.com.au`, `newcastleslushiehire.com.au`) are excluded from execution, including when present in a managed row's alias list. This implementation does not authorize production migration or establish live DNS, public-CA issuance, customer-proxy compatibility, or future scheduled renewal acceptance.
