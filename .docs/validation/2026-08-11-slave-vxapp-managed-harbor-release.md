# Slave Managed-Harbor Application Release Acceptance — 2026-08-11

## Outcome

**PASS — DEVELOPMENT APPLICATION DELIVERY.** The repository-owned
`slave-vxapp` adapter completed a normal tenant release through Vesta-managed
Harbor and generic `standard` profile version 2 orchestration. The release
used only the `slave` SSH identity, advanced the managed project to revision
4, passed full container-readiness health and exact drift, and returned HTTPS
200 through the API-owned public route.

This record accepts the development application-delivery path. It does not
authorize production, claim a Harbor provider-backup acceptance, or replace
the separately preserved 2026-08-08 failure history. No production endpoint
was contacted or changed.

## Authority and release identity

| Field | Accepted value |
| --- | --- |
| Application repository | `slave-vxapp` |
| Source commit | `06178345d2e9f627483fafc2d347bbe7d7eb8e83` |
| SSH identity | `slave@192.168.200.100` with the configured tenant key |
| Owner/project | `slave/slave-vxapp` |
| Profile | `standard` version 2 |
| Registry | `dev.jackpridham.com:8083` |
| Repository | `dev.jackpridham.com:8083/vx-slave/slave-vxapp` |
| Immutable image | `sha256:e4e1aade91f49a709041949149a073cb731c97f6ab3134a02d133ae58b70998b` |
| Resulting revision | `4` |
| Public route | `https://dev.jackpridham.com/` |

The application commit was clean, matched the remote development ref, and
passed the focused deployment adapter, image-contract, ESLint, TypeScript,
and Vitest checks before release. The Vesta runtime source commit installed on
the host was not independently asserted by this application transaction.

## Accepted transaction

The adapter performed the following bounded sequence:

1. queried the owner, project, profile, and current revision as `slave`;
2. called `registry-info`, which refreshed and returned healthy, fresh managed
   provider state plus the exact owner repository;
3. generated a temporary native age identity and sent only its recipient to
   publisher rotation through bounded SSH stdin;
4. decrypted the one-time Harbor publisher credential directly into Docker
   login using a protected local credential helper;
5. built and pushed the application for `linux/amd64` outside Vesta;
6. resolved and rendered the immutable repository digest rather than a tag;
7. sent Compose through SSH stdin for `change` preview;
8. used the exact returned preview ID, source digest, candidate digest, and
   expected revision for preview-bound image pull and apply; and
9. required post-apply project identity, full-readiness health, exact drift,
   and public HTTPS acceptance.

No Debian SSH, raw Docker on the Vesta host, Docker socket/group access,
direct `sudo v-*`, image archive, local-image approval, SCP, rsync, or direct
Compose command was used.

## Final evidence

The independent post-apply reads returned:

```text
owner=slave
project=slave-vxapp
profile=standard
state=running
revision=4
health=healthy
health_freshness=fresh
app_runtime_state=running
app_health=healthy
failing_streak=0
restart_count=0
drift_match=true
changed_services=[]
missing_services=[]
extra_services=[]
registry_state=ready
registry_health=healthy
registry_freshness=fresh
public_http_status=200
public_remote_ip=192.168.200.100
public_tls_verify=0
```

The running image reported the same accepted repository digest:

```text
dev.jackpridham.com:8083/vx-slave/slave-vxapp@sha256:e4e1aade91f49a709041949149a073cb731c97f6ab3134a02d133ae58b70998b
```

## Fail-closed evidence and credential storage

Earlier attempts stopped without workload mutation when tenant broker access
was denied and when provider discovery returned stale/unavailable health. On
the accepted date, provider discovery passed but the first publisher login
stopped before build because Docker's installed `secretservice` helper had no
persistent `login` collection in the headless SSH session.

The builder was changed to Docker's `pass` helper backed by a dedicated GPG
key with encryption capability. A disposable non-secret store/get/erase round
trip passed, Docker configuration remained mode 0600 with no inline `auth`,
and the release was retried. The retry performed a fresh publisher rotation;
no plaintext or inaccessible prior generation was recovered or reused.

Final `registry-info` reported `PUBLISHER_ENABLED=true`. The accepted
application transaction did not include the tenant guide's
post-publication disable/logout operation, so this record does not claim
publisher revocation acceptance. The publisher credential remains only in the
protected local helper and a later rotation replaces it. Maintainers should
use the canonical disable/logout step when closing a bounded publication
window.

## Remaining boundaries

- Production deployment remains deferred and requires separate authorization
  naming the host, immutable release, workload mutation, approval, and
  rollback/continuity scope.
- Harbor provider backup and restore retain their documented first-release
  disabled boundary; this application release does not change it.
- Revision 4 and the digest above are dated evidence only. Application
  adapters must continue querying the current revision and registry repository
  rather than hard-coding either value.
- The historical
  [2026-08-08 development record](2026-08-08-vesta-managed-harbor-development.md)
  remains authoritative for its failed attempts and rollback evidence; this
  record supersedes only its statement that corrected application delivery
  had not yet succeeded.
