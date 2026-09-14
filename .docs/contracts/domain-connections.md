# Native domain connections (version 1)

Vesta owns the global hostname reservation and native child state.  The API
owns tenant intent and primary selection.  A connection is never a second Site.

## Commands

```
v-add-vx-web-domain-connection USER TECHNICAL_FQDN HOSTNAME REQUEST_ID [json]
v-list-vx-web-domain-connections USER TECHNICAL_FQDN [json]
v-reconcile-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-delete-vx-web-domain-connection USER TECHNICAL_FQDN CONNECTION_ID [json]
v-update-vx-web-domain-connections [json]
```

Creation persists a root-owned reservation before native mutation and is
idempotent only when owner, technical FQDN, hostname, and `REQUEST_ID` match.
The default capability has `enrollmentEnabled:false`; this never stops
reconciliation or cleanup of existing records.  Reconcile performs one bounded
attempt.  List is cached and read-only.

The capability command is `v-list-vx-web-domain-connection-capability json`:

```json
{"version":1,"capabilities":{"enrollmentEnabled":false,"connectionTarget":"target.example","ingress":{"ipv4":[],"ipv6":[],"supportsApex":false},"supportedStates":["pending_verification","pending_dns","pending_tls","connected","degraded","disconnecting","disconnected","failed","recovery_required"]}}
```

Create, reconcile, and delete return `{version:1,connection,quota}`.  `connection`
contains `connectionID`, `technicalFQDN`, `hostname`, `generation`, `state`,
`reason`, TXT `proof`, public `instructions`, check timestamps, and sanitized
component `observations`.  Lists return `{version:1,connections:[connection],quota}`
with the same recoverable TXT proof and instructions.  `observations.native`
contains only native-child presence, TLS state, HTTPS identity, and config
validity; it never contains copied proxy headers or values.

States are `pending_verification → pending_dns → pending_tls → connected`;
connected health failures become `degraded`. Cleanup is `disconnecting →
disconnected`; terminal invalid input is `failed` and uncertain native work is
`recovery_required`. A successful connection requires accepted certificate,
native configuration, and public HTTPS identity.

Hostnames are lower-case IDNA (Python `idna`) and are checked against maintained
`libpsl` through its shared library; URLs, ports, IPs, wildcards, reserved names, and public
suffixes such as `com.au` are rejected. Records live under
`data/vx/domain-connections/hostnames/<sha256>.json`, are validated against the
inside hostname, atomically written `0600`, and protected by owner-before-hostname locks (with a two-second acquisition bound). The native authority is checked before reservation.

The worker accepts compact DNS/CAA/DNSSEC/ingress observations only. It does
not make customer DNS changes, issue arbitrary probes, expose private proxy
metadata, or route tenant content before proof and TLS acceptance.


Registry authority requires root-owned, non-symlink ancestors and `0700` registry
and hostname directories. Records and locks are `0600`, regular, single-link
files. Read-only lists, quota, and health use those same checks and never repair
permissions or initialize state. Mutating and read adapters require root at the
existing authenticated Vesta command boundary; no tenant sudo is introduced.

Quota is the native `WEB_DOMAINS` limit (`unlimited` is unlimited; `0` is zero)
minus native primary rows and active reservations without a native row. The
optional connection limit is an additional per-owner cap. Disconnected records
and expired, untouched proofs release capacity. Reclaim uses a fresh ID/token
and a higher generation, after checking current native primaries and aliases;
uncertain cleanup never releases a reservation. Repeating the same request
returns its durable record even when enrollment has subsequently been disabled.

The worker starts at most 20 due records per run, stops starting work after a
120-second budget, and limits each attempt to the smaller remaining budget or
90 seconds (plus a ten-second termination grace). Owner locks precede hostname
locks throughout native actions. Failed observations back off from 60 seconds
to one hour; accepted health is checked hourly. `v-update-vx-web-domain-connections
json` returns `{checkedAt,lastCompletedAt,processed,overdue}` and queue
`domain-connections` invokes the worker directly. The existing minute restart
queue also starts it independently, with the restart lock descriptor closed;
worker serialization prevents overlapping batches. Lists never perform DNS/HTTPS
checks. Public observations include cached native certificate expiry and renewal
results, without configuration or trusted-header values.

`OPERATION` persists kind, generation, and start time before create, initial
issuance, activation, and cleanup. `CLEANUP.NATIVE_GENERATION` retains the exact
native marker generation across repeated disconnects. Readback precedes issuance,
so a lost response with an accepted/installed certificate does not issue again.
Only native `v-update-letsencrypt-ssl` schedules renewal. Failed native operations
retain recoverable intent; saved certificate recovery runs under the same locks.
Restored records require a fresh proof before activation.

Shared target changes persist `target-operation.json` before any provider write.
A random operation comment permits exact POST readback after process loss; an
unrelated existing record is never adopted. The previously accepted `target.conf`
remains authoritative until both desired address families pass readback. A
pending change must be resumed with identical input. Both target configuration
and pending intent prevent Cloudflare zone rotation, even with no technical sites.
