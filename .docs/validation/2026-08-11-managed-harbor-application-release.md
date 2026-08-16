# Managed-Harbor Application Release Acceptance — 2026-08-11

## Outcome

**PASS — DEVELOPMENT APPLICATION DELIVERY.** A repository-owned deployment
adapter completed a normal tenant release through Vesta-managed Harbor and the
generic `standard` profile. The release used only the owning tenant SSH
identity, advanced the managed project revision, passed full container
readiness and exact drift, and returned HTTPS 200 through its public route.

This dated record accepts the reusable development application-delivery path.
It does not authorize production, claim Harbor provider-backup acceptance, or
replace earlier failure and rollback evidence. No production endpoint was
contacted or changed.

Private source, tenant, project, endpoint, route, and artifact identifiers have
been replaced with semantic evidence labels. The protected operational record,
not this repository, retains the exact values required for incident response.

## Accepted authority shape

| Field | Accepted requirement |
| --- | --- |
| Application repository | Clean, remotely recoverable application source with a repository-owned adapter |
| SSH identity | Owning non-administrator Vesta/Unix tenant using its configured key |
| Owner/project | Owner-equal tenant and existing managed project |
| Profile | Generic `standard` profile at the installed version |
| Registry | Fresh origin returned by `registry-info`; never reconstructed by the adapter |
| Repository | Exact owner/project repository returned by `registry-info` |
| Immutable image | Exact `repository@sha256:<digest>` resolved after publication |
| Resulting revision | Positive revision greater than the pre-release revision |
| Public route | Application-owned HTTPS route validated without recording its hostname here |

The source commit was clean, matched its configured remote development ref,
and passed the repository's focused deployment-adapter, image-contract,
linting, type, and unit checks before release. The application transaction did
not independently assert the Vesta runtime source commit; control-plane release
identity is a separate operator preflight requirement.

## Accepted transaction

The adapter performed this bounded sequence:

1. queried the owner, project, profile, state, and current revision as the
   owning tenant;
2. called `registry-info`, which refreshed and returned healthy, fresh managed
   provider state plus the exact owner repository;
3. generated a temporary native age identity and sent only its recipient to
   publisher rotation through bounded SSH stdin;
4. decrypted the one-time publisher credential directly into Docker login
   using a protected local credential helper;
5. built and tested the application for the approved platform outside Vesta;
6. pushed a versioned publication tag, then resolved and rendered the immutable
   repository digest rather than deploying the tag;
7. sent Compose through SSH stdin for an immutable `change` preview;
8. validated and reused the exact preview ID, source digest, candidate digest,
   expected revision, owner, project, profile, and mode for preview-bound image
   pull and apply; and
9. required post-apply project identity, successful operation, forward
   revision, full-readiness health, exact drift, application acceptance,
   manifest-bound rollback preview, and public HTTPS acceptance.

No administrator SSH, raw Docker on the Vesta host, Docker socket/group access,
direct `sudo v-*`, image archive, local-image approval, SCP, rsync, or direct
Compose command was used.

## Final evidence shape

Independent post-apply reads established:

```text
owner=<expected-owner>
project=<expected-project>
profile=standard
state=running
revision=<forward-positive-revision>
health=healthy
health_freshness=fresh
application_runtime_state=running
application_health=healthy
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
public_tls_verify=0
```

The running service reported the same immutable repository digest accepted by
the preview. Exact private values remain outside the repository.

## Fail-closed and credential evidence

Earlier attempts stopped without workload mutation when tenant broker access
was denied and when provider discovery returned stale or unavailable health.
One publication attempt stopped before build because the installed credential
helper lacked usable protected backing storage in the headless SSH session.

The builder was changed to an encryption-capable credential store. A disposable
non-secret store/get/erase round trip passed, Docker configuration remained
mode `0600` with no inline `auth`, and the release was retried with a fresh
publisher rotation. No plaintext or inaccessible prior generation was
recovered or reused.

The accepted transaction did not include post-publication publisher disablement
or logout. This record therefore does not claim publisher-revocation
acceptance. The canonical workflow now requires disable/logout when closing a
bounded publication window; a later rotation replaces any retained generation.

## Remaining boundaries

- Production remains deferred and requires separate authorization naming the
  target, immutable release, workload mutation, approval, and
  rollback/continuity scope.
- Harbor provider backup and restore retain their documented first-release
  disabled boundary.
- Dated revisions and digests are evidence only. Adapters must query current
  authority rather than hard-coding either value.
- Earlier development records remain authoritative for their failed attempts
  and rollback evidence; this record supersedes only their statement that a
  complete generic application-delivery transaction had not yet succeeded.
