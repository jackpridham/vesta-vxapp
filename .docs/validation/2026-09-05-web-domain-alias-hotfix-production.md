# Web-domain alias-sentinel production hotfix

## Authorization and scope

The operator explicitly requested the quickest production deployment of
`48e020eb777db50dbe9d53857586e545179dafa0`. The transaction was limited to
`bin/v-add-web-domain`; quota migration, workload, route, package, secret,
provider, domain, and service mutations were excluded.

Production retained its accepted `572fa7f8` release markers because five
unrelated runtime templates exist between that base and the hotfix commit but
were outside this request. Runtime authority is therefore the accepted base
plus the exact one-file overlay, rather than a misleading full-commit stamp.

## Release and preflight evidence

The worktree was clean, `HEAD` equalled `origin/master`, and the immutable
hotfix commit was recoverable from that remote. The repository-owned limited
readiness launcher passed against the exact source with its CPU, memory, swap,
task, and nice limits intact. The expected root-only disposable-container test
was skipped; all runnable stages passed, including Bash syntax, bounded
ShellCheck, Compose suites and fixtures, PHP and JavaScript checks,
documentation consistency, and discovery of 31 Playwright tests in 16 files.

The deterministic one-file archive SHA-256 was
`8c01a40887a97ed79fce0a1b119e57595d2ea573013d233b4fbb4672ea88fdda`.
The manifest SHA-256 was
`d69cd181f4229e61819122b733157e5dc7b28cf259a382e3494faf0ab8ccfab8`.
Preflight verified the authorized production identity, accepted base marker,
exact old command hash and metadata, free release lock, no recovery marker,
sufficient rollback capacity, dependencies, active services, valid nginx and
Apache configuration, active mount guard, healthy managed workloads, and
preserved stopped rollback authority.

## Protected transaction and acceptance

The transaction held `/run/lock/vesta-vxapp-release.lock`, created and verified
an exact protected rollback copy before mutation, extracted and checked the
archive in a protected root staging directory, and atomically installed only
the allowlisted command. The live command is a regular executable owned by
`root:root`, mode `0755`, with SHA-256
`a566d7a6a029a3bf28ba2cc580bd17d5c40bc182e064d9eb2f80121d0cb71ab9`.
Bash syntax, nginx and Apache configuration, service identities, restart
counts, container identities, images, health, and states were unchanged.

Independent before/after continuity snapshots matched byte-for-byte across
the bounded persisted authority, access groups, mount guard, recovery state,
stopped external rollback authority, and retained rollback volumes. The panel
endpoint returned its expected HTTP 302. The release lock was free, no recovery
marker remained, and both exact transient transfer directories were removed.
No service was reloaded or restarted.

The protected exact-file rollback root is
`/var/backups/vesta-vxapp-releases/48e020eb-2ifVA828`. This validation record
describes one authorized production window; it is not standing authorization.

## Observed unrelated limitation

The read-only project view reports a pre-existing false drift difference for
one compatibility workload because desired Linux capabilities omit the
`CAP_` prefix while Docker's equivalent observation includes it. Image,
mounts, ports, state, revision, effective capabilities, health, and restart
count match. This hotfix did not change or reconcile that workload.
