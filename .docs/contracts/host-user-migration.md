# Host and User Migration Contract

## Scope

Vesta owns two source-push migration commands:

```text
v-migrate-host [TARGET] [PORT] [IDENTITY] [FORCE]
v-migrate-user USER [TARGET] [PORT] [IDENTITY] [NORMALIZE]
```

`TARGET` is `root@hostname`. Missing connection values are prompted for.
`IDENTITY` is a regular private-key path or `-` to let OpenSSH use its agent
and interactive authentication. Vesta never accepts, reads, stores, logs, or
places an SSH password in argv or environment variables.

Both commands require local root. The receiver requires remote root. A single
OpenSSH control connection is reused for staging and apply so an interactive
operator normally authenticates once. Host-key verification uses
`StrictHostKeyChecking=accept-new`; changed keys remain a hard failure.

## Host migration

Host migration transfers:

- the installed `/usr/local/vesta` application and shipped assets;
- the source service-selection profile used to drive the bundled installer;
- an allowlisted merge of non-secret Vesta service, port, and language values;
- installed Vesta-related package names that remain available on the target;
- allowlisted service configuration below `/etc`;
- one native Vesta backup for `admin`.

It excludes every non-admin user and site, Vesta database credentials, Vesta
TLS keys, runtime queues, sessions, logs, IP authority, firewall state, SSH
configuration, host identity, network configuration, filesystems, and DNS
cutover. The installer establishes target-local credentials, certificates,
IP state, and host identity. The transferred Vesta tree is overlaid afterward
so the source instance's command implementation is authoritative.

A fresh install requires a clean target without Vesta or an `admin` system
account. An existing Vesta target requires `FORCE=yes`, must contain no
non-admin Vesta users, and receives a best-effort pre-migration archive under
`/var/backups`. Source and target Debian major versions must match.

## User migration

User migration accepts one explicit, existing, unsuspended, non-admin user.
It creates a native `v-backup-user` archive, including web, DNS, mail,
databases, cron, user directories, legacy Docker metadata, and managed Compose
projects according to the native backup contract. The target must already be
provisioned with Vesta and must not contain that user. Native restore remains
responsible for rejecting domain or database conflicts.

After restore, Vesta rebuilds the user, optionally normalizes restored DNS to
target authority, refreshes counters, and reconciles managed runtime state.
The source user remains intact.

## Archive and mutation safety

Migration stages use root-only temporary directories. Outer archives and
every payload member have SHA-256 manifests. The receiver rejects checksum
mismatch, unsupported schema, absolute or traversal paths, outer links and
special files, unexpected payload sets, install-root escape, invalid native
backup names, OS mismatch, target user collision, and unexpected target
state before applying data.

Migration never deletes source data, changes public DNS delegation, performs
global Docker cleanup, transfers raw Docker daemon state, or copies SSH,
network, firewall, registry credentials, or external storage configuration.
