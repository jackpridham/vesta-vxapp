# Compose Security Contract

## Baseline

The policy engine applies these defaults to generated simple workloads:

- `cap_drop: [ALL]`;
- no `cap_add`;
- `security_opt: [no-new-privileges:true]`;
- `init: true`;
- explicit non-root user when the image contract supplies one;
- read-only root filesystem when the workload contract supports it;
- bounded CPU, memory, and PIDs;
- bounded `nofile`;
- bounded stop grace period;
- `json-file` logging with rotation;
- bridge networking with no published port unless requested;
- localhost binding for HTTP routes.

Advanced Compose must declare equivalent or stronger settings; policy never
silently weakens a submitted workload to make it pass.

## Absolute rejections

No profile permits privileged mode, Docker socket mounts, host PID/IPC,
devices, daemon API access, arbitrary host paths, ownership-label overrides,
or broad system directory mounts.

## Capability allowlists

The standard allowlist is empty. Administrator profiles name exact additions.
The workload-specific `legacy-admin-app` profile permits only:

`CHOWN`, `DAC_OVERRIDE`, `KILL`, `SETGID`, and `SETUID`.

It remains bridge-only, managed-storage-only, localhost-published, and
administrator-assigned. Exact-workload testing proved that removing `CHOWN`,
`DAC_OVERRIDE`, `SETGID`, or `SETUID` makes the workload unhealthy. A
read-only-root candidate stopped cleanly without `KILL`, but managed backup,
restore, rollback, reinstall, and profile-migration gates are not yet
available for that candidate, so version 2 conservatively retains `KILL`.
It does not add networking, device, host-path, or namespace authority and does
not weaken `standard`.

## Read-only-root compatibility boundary

The current `legacy-admin-app` image can run with a read-only root only when four
bounded tmpfs mounts are present and its entrypoint recreates exact Nginx and
Supervisor runtime directories. Global policy continues to reject tmpfs, and
the current approved image lacks that initialization. No live profile change
is authorized by the staging study.

Any future profile revision must exact-allowlist tmpfs targets/options/sizes,
use an immutable compatible image, migrate assignment authority
transactionally, and pass health, HTTP, restart, graceful stop/start, backup,
validation restore, revision rollback, reinstall, redaction, and unrelated
state gates.

Capabilities are compared case-insensitively after canonicalization. `ALL` in
`cap_add` is always rejected.

## Host networking

Host networking is rejected for every profile. Workloads use managed bridge
networks and explicit validated port publications. Applying firewall policy is
never automatic.

## Audit and redaction

Audit records contain actor, owner, project, action, policy/profile versions,
digests, image IDs, result, and redacted errors. They exclude environment
values, secret values, registry passwords/tokens, Compose auth blobs, and
complete command lines containing temporary paths. Redaction tests use unique
synthetic canaries and fail if any canary appears.

Deployment plans read image references only from canonical desired state and
may include existing immutable `images.json` identity evidence. Preview never
resolves or pulls an image. Plans expose managed secret names only; they never
read or return managed secret contents, registry authentication, caller
environment, or unredacted Docker errors.
