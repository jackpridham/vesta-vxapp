# Compose Project Storage Contract

## Authority and scope

This contract defines canonical per-user project storage, stable project
identity, ownership, labels, revisions, locks, and durable workload paths.
Docker Compose is the workload source of truth.

## Identifiers

- User is an existing Vesta username.
- Project key matches `^[a-z0-9][a-z0-9-]{0,62}$`.
- Runtime Compose project name is exactly `vx-<user>-<project>`.
- A runtime object is managed only when all labels match:
  - `com.docker.compose.project=vx-<user>-<project>`;
  - `vx.managed=yes`;
  - `vx.user=<user>`;
  - `vx.project=<project>`.
- User/project resolution occurs before every filesystem or Docker operation.

## Protected control-plane layout

The canonical root is:

```text
/usr/local/vesta/data/users/<user>/docker-projects/<project>/
├── compose.yaml
├── project.conf
├── routes.conf
├── variables.env
├── audit.log
├── secrets/
├── revisions/<revision>/
│   ├── compose.yaml
│   ├── project.conf
│   ├── routes.conf
│   └── manifest.sha256
└── runtime/
    ├── workload-secrets/current/
    ├── last-operation.json
    ├── last-health.json
    └── backup-manifest.json
```

`compose.yaml` is canonical Compose input. `project.conf` stores only Vesta
metadata such as owner, profile, revision, lifecycle state, timestamps,
resource counters, and image identities. It must never contain secret values.
`routes.conf` stores Vesta-owned HTTP route bindings outside Compose.
`variables.env` contains allowlisted, non-secret interpolation values.

Directories are root-owned and not writable by the tenant account. Control
files are mode 0640 unless a stricter contract applies. `secrets/`,
`variables.env`, registry auth, operation state containing command output, and
all files beneath `secrets/` are mode 0700/0600 as appropriate.
`runtime/workload-secrets/` is disposable authority-only state: its parent and
active directory are mode `0700`, its exact container-mounted files are mode
`0444`, and it is excluded from revisions, backup archives, restore inputs,
and public metadata.

## Durable data layout

Tenant bind data is rooted at:

```text
/home/<user>/docker/<project>/binds/<name>/
```

Managed named volumes use the stable Docker name:

```text
vx_<user>_<project>_<volume>
```

and carry the four ownership labels above plus `vx.volume=<volume>`.
Anonymous volumes are rejected. Bind sources are resolved with symlinks
removed and must stay below the project bind root. Administrator authority
does not permit arbitrary host paths.

## Revisions and atomicity

- Revisions are monotonically increasing, zero-padded integers.
- A revision is immutable after its manifest is written.
- New files are written to a sibling temporary path, fsynced where supported,
  chmod/chowned, and renamed into place.
- The current revision changes only after validation succeeds.
- One `flock` lock at
  `/usr/local/vesta/data/users/<user>/docker-projects/.locks/<project>.lock`
  serializes all mutations.
- Readers may inspect the last complete revision while a mutation is active.

## Ownership and deletion

- Cross-user reads and writes are rejected before Docker is queried.
- Admin access changes authorization, not project ownership or labels.
- Removing a project deletes control metadata only after runtime removal
  succeeds or the operator explicitly uses a metadata-only recovery action.
- Managed data and volumes are retained by default. The current public remove
  command exposes only retained-data removal; any future purge path must be a
  distinct destructive operation with backup-state checks and audit evidence.
- Global prune commands are forbidden.
