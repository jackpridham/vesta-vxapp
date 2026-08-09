# Compose Policy and Quota Contract

## Validation pipeline

Every generated, imported, restored, adopted, or updated project passes the
same pipeline:

1. resolve and lock user/project paths;
2. copy input to a protected staging directory without following symlinks;
3. render with a controlled `HOME`, `DOCKER_CONFIG`, project name, and
   Vesta-owned non-secret env file;
4. run `docker compose config --format json`;
5. reject unresolved interpolation and unsupported Compose keys;
6. canonicalize JSON ordering and derive a normalized policy view with `jq`;
7. enforce profile, path, image, network, port, security, and quota rules;
8. write a redacted validation result and audit event;
9. permit lifecycle mutation only when the canonical digest still matches.

Policy evaluates the rendered model, never YAML text or UI fields alone.

## Profiles

| Profile | Assignment | Network | Host paths | Security additions |
| --- | --- | --- | --- | --- |
| `standard` | Package/user eligible | Bridge only | Managed project roots | Safe defaults only |
| `admin-approved` | Admin per project | Bridge; approved public binds allowed | Managed project roots | No capability additions |
| `legacy-admin-app` | Admin per project | Bridge only | Managed project roots | `CHOWN`, `DAC_OVERRIDE`, `KILL`, `SETGID`, `SETUID` only |

Approval is stored in root-owned mode-0600 Vesta metadata with actor, timestamp,
profile version, and a required UTC expiry no more than one year ahead. A
Compose declaration cannot grant itself a profile.

## Deny-first rules

All profiles reject:

- `privileged`;
- Docker/Containerd sockets and daemon control paths;
- host PID or IPC namespaces;
- devices and CDI devices;
- arbitrary `/`, `/etc`, `/proc`, `/sys`, `/dev`, `/run`, Vesta data, or
  another user's home binds;
- symlink escapes from allowed roots;
- automatic bind-source creation (`bind.create_host_path: true`); generated
  simple workloads use explicit long syntax with `create_host_path: false`
  after Vesta creates the exact managed directory;
- unbounded or anonymous volumes;
- unsafe command/environment interpolation from the caller shell;
- Compose build directives on the managed host;
- credential-bearing URLs or secret-like values in labels, environment,
  commands, health checks, or annotations;
- overriding Vesta ownership labels or Compose project identity.

Vesta creates the authority-owned `docker/<project>/binds` traversal one
component at a time. Existing symlinks and unexpected owners fail closed;
directory file-descriptor identity is checked before and after ownership/mode
changes. Tenant-owned direct bind leaves use the same no-follow identity
boundary, so a tenant-controlled symlink cannot redirect a root metadata
change.

Each owner root containing a real managed project is protected by a
self-bind mount. The boot guard discovers only validated `project.conf`
authorities, restores those mounts before Docker/containerd, and is required
and ordered before Docker through a packaged systemd drop-in. Activation
performs the one-time legacy owner-to-root transition before installing that
dependency edge. Empty owner directories are skipped; linked or mismatched
authority entries fail closed. Owner deletion explicitly unmounts only that
owner root.

The `standard`, `admin-approved`, and `legacy-admin-app` profiles reject host
networking. `standard` and `admin-approved` reject every `cap_add`;
`legacy-admin-app` accepts only `CHOWN`, `DAC_OVERRIDE`, `KILL`, `SETGID`, and
`SETUID` after an expiring root assignment. These are the exact capabilities
required by the existing image to prepare Nginx runtime directories, change
PHP-FPM identity, and stop Supervisor children. All projects also
reject custom security options, user namespace overrides, kernel tunables,
and custom logging drivers.

## Package quotas

Compose workload quota fields use integer values; `0` disables the capability
and `unlimited` has the normal Vesta meaning:

- `DOCKER_PROJECTS`;
- `DOCKER_SERVICES`;
- `DOCKER_CPUS`;
- `DOCKER_MEMORY_MB`;
- `DOCKER_PIDS`;
- `DOCKER_STORAGE_MB`;
- `DOCKER_PORTS`;
- `DOCKER_SECRETS`;
- `DOCKER_VOLUMES`.

Usage counters use matching `U_` names. Validation sums the requested rendered
limits across all owner projects. A service without CPU, memory, or PID limits
is rejected. Storage usage includes project definitions, protected revisions,
retained project data roots, managed bind data, and managed named-volume usage
where it can be measured by the volume helper. It is measured before deploy,
update, and periodic counter refresh. Exceeding a quota blocks growth and
start-like operations with a redacted diagnostic; it never deletes data.

`v-list-docker-compose-quota USER [FORMAT]` is the authoritative read
diagnostic. Its stable uppercase JSON reports the configured package,
effective user, and persisted `U_` usage values for all nine dimensions as
`PACKAGE_VALUE`, `EFFECTIVE_VALUE`, and `USED`. CPU values retain three decimal
places and memory/storage units are MiB. Legacy `DOCKER_CONTAINERS=unlimited`
packages retain their compatibility defaults.

`DOCKER_REGISTRY_MB` and `U_DOCKER_REGISTRY_MB` are a tenth, separate package
and usage pair for the optional Vesta-managed Harbor provider. They are not
part of rendered Compose workload quota calculation or the nine-row
`v-list-docker-compose-quota` response. An existing eligible `standard`
project discovers its managed registry quota and freshness through
`v-docker registry-info PROJECT json`; external registries do not consume this
Harbor artifact quota.

Workload-specific limits use a dedicated package merged from the owner's
current non-Docker package values. They never modify the shared default
package. Any production package transition requires byte-exact rollback
capture, before/after hashes, counter recalculation, authoritative assertions,
and separate production authorization. Rollback reinstalls the hash-verified
prior package and user bytes at their exact Vesta paths, removes only the
dedicated transition package, and byte-compares both restored targets.

For tenant shell access, the effective package-derived `DOCKER_PROJECTS`
value must be positive or `unlimited`; `0` disables access. Interactive Bash
is also required. Vesta owns automatic reconciliation of the derived
`vesta-compose-users` membership, while the exact
`v-run-user-docker-command` broker rechecks live entitlement under the owner
lock on every `v-docker` call. Membership alone is never authority. The
tenant surface remains owner-equal, `standard`-only, redacted, and accepts
payloads only through bounded stdin.

## Resource minimums and canonical units

- CPU is stored as decimal cores with three fractional digits.
- Memory/storage package fields and policy facts use integer MiB.
- PIDs are positive integers.
- Docker Compose expands matching port ranges during canonicalization; each
  published port is validated and counted individually.
- Replicas and scaling are rejected on this single-host implementation.

## Policy versions

Each accepted revision records policy schema version, selected profile version,
canonical Compose SHA-256, and validator version. Unsupported stored policy
versions fail closed during quota and start-like lifecycle checks without
mutating the project automatically. Operators must update or roll back the
project through the audited lifecycle commands after policy changes.
