# Docker Container Schema Contract

> **Historical contract (superseded 2026-07-25):** This describes the shipped
> direct-container MVP. New orchestration work follows
> [Compose storage](compose-storage.md),
> [lifecycle](compose-lifecycle.md), and
> [interfaces](compose-interfaces.md). Do not extend this record format as the
> Compose source of truth.

## Scope

This contract defines:

- the create/update spec file consumed by `bin/v-add-docker-container` and `bin/v-change-docker-container`
- the persisted record format stored in `data/users/<user>/docker.conf`
- exact field names, types, defaults, allowed values, and validation rules

At the time of the direct-container MVP, this contract was the source of truth
for the Bash and PHP implementation tasks in
`.docs/plans/2026-06-27-docker-panel-management.md`.

## File Format

Both the create/update spec file and `data/users/<user>/docker.conf` use Vesta-style shell assignment records.

- Encoding: ASCII
- Line format for spec files: `KEY='VALUE'`
- Line format for persisted records: one container record per line, with `KEY='VALUE'` pairs separated by spaces
- Quoting: single-quoted shell literals
- Empty values: `KEY=''`
- List delimiter inside a single field: `||`
- Timestamp format: `YYYY-MM-DD HH:MM:SS`

## Create/Update Spec Contract

The following fields are accepted from the temp spec file passed to `bin/v-add-docker-container` and `bin/v-change-docker-container`.

| Field | Type | Required | Default | Allowed values | Validation |
| --- | --- | --- | --- | --- | --- |
| `NAME` | string | yes | none | lowercase service name | `^[a-z0-9][a-z0-9-]{0,62}$`; must be unique per owner; must not be `admin`; no trailing `-` |
| `IMAGE` | string | yes | none | Docker image reference | non-empty; max 255 chars; no spaces; allow registry/repo/tag or digest forms |
| `COMMAND` | string | no | `''` | free text command override | max 1024 chars; may contain spaces; must not contain newlines |
| `ENV` | list-string | no | `''` | `KEY=VALUE` entries joined by `||` | each entry must match `^[A-Z0-9_][A-Z0-9_]*=.*$`; no newlines; empty list allowed |
| `MOUNTS` | list-string | no | `''` | `<relative_name>:<container_path>` entries joined by `||` | `relative_name` must match `^[a-z0-9][a-z0-9_-]{0,63}$`; `container_path` must be absolute and start with `/`; host side is always rooted under `/home/<user>/docker/<NAME>/` |
| `CONTAINER_PORT` | integer-string | yes | none | `1` to `65535` | numeric only; container-facing port only |
| `DOMAIN` | string | no | `''` | owned web domain FQDN | empty or must exist in the owner's web domains; exact match to a domain in `web.conf` |
| `ROUTE_PATH` | string | no | `''` | URL path prefix | empty or must begin with `/`; `/` is normalized to `''`; max 128 chars; no spaces; no `?` or `#` |
| `AUTO_START` | enum | no | `yes` | `yes`, `no` | exact lowercase match |
| `RESTART_POLICY` | enum | no | `unless-stopped` | `no`, `on-failure`, `always`, `unless-stopped` | exact lowercase match |
| `HEALTHCHECK_TYPE` | enum | no | `http` | `http`, `tcp`, `docker`, `none` | exact lowercase match |
| `HEALTHCHECK_TARGET` | string | no | derived | URL, `host:port`, or empty | defaults to `http://127.0.0.1:<CONTAINER_PORT>/health` when `HEALTHCHECK_TYPE='http'` and the field is omitted; required when `HEALTHCHECK_TYPE` is `http` or `tcp`; empty when `HEALTHCHECK_TYPE` is `none`; for `http`, must match `^https?://`; for `tcp`, must match `^[A-Za-z0-9.-]+:[0-9]{1,5}$` |
| `HEALTHCHECK_INTERVAL` | integer-string | no | `60` | `15` to `3600` seconds | numeric only |
| `CPU_ALERT_PCT` | integer-string | no | `85` | `1` to `1000` | numeric only |
| `MEM_ALERT_MB` | integer-string | no | `1024` | `1` to `1048576` | numeric only |
| `NET_ALERT_MBPS` | integer-string | no | `50` | `1` to `100000` | numeric only |
| `ALERT_EMAIL` | enum | no | `yes` | `yes`, `no` | exact lowercase match |

### Canonical Spec Example

```bash
NAME='app'
IMAGE='ghcr.io/example/app:latest'
COMMAND=''
ENV='PORT=3000||NODE_ENV=production'
MOUNTS='data:/srv/app/data||config:/srv/app/config'
CONTAINER_PORT='3000'
DOMAIN='app.example.com'
ROUTE_PATH=''
AUTO_START='yes'
RESTART_POLICY='unless-stopped'
HEALTHCHECK_TYPE='http'
HEALTHCHECK_TARGET='http://127.0.0.1:3000/health'
HEALTHCHECK_INTERVAL='60'
CPU_ALERT_PCT='85'
MEM_ALERT_MB='1024'
NET_ALERT_MBPS='50'
ALERT_EMAIL='yes'
```

## Persisted Record Contract

Each record in `data/users/<user>/docker.conf` represents one managed container owned by `<user>`.

### Persisted Fields

| Field | Type | Source | Validation / meaning |
| --- | --- | --- | --- |
| `NAME` | string | spec | Logical container name; matches spec `NAME` |
| `CTN_NAME` | string | derived | Runtime Docker container name; exact format `vx-<owner>-<name>` |
| `OWNER` | string | derived | Vesta username that owns the container; must match the file path owner |
| `IMAGE` | string | spec | Copy of requested image reference |
| `COMMAND` | string | spec | Copy of command override |
| `ENV` | list-string | spec | Copy of normalized env entries |
| `MOUNTS` | list-string | spec | Copy of normalized mount entries |
| `HOST_PORT` | integer-string | derived | Allocated localhost port; numeric; reserved runtime port published on `127.0.0.1` |
| `CONTAINER_PORT` | integer-string | spec | Container-facing port |
| `DOMAIN` | string | spec | Empty or owned route domain |
| `ROUTE_PATH` | string | spec | Empty or normalized path prefix |
| `PROXY_MODE` | enum | derived | Current routing mode; `proxy` when a domain is linked, otherwise `''` |
| `PROXY_TARGET` | string | derived | Empty or exact target `http://127.0.0.1:<HOST_PORT>` |
| `AUTO_START` | enum | spec | `yes` or `no` |
| `RESTART_POLICY` | enum | spec | `no`, `on-failure`, `always`, or `unless-stopped` |
| `HEALTHCHECK_TYPE` | enum | spec | `http`, `tcp`, `docker`, or `none` |
| `HEALTHCHECK_TARGET` | string | spec or derived | Health endpoint target; when routed to localhost, implementations may rewrite to `HOST_PORT` before persisting |
| `HEALTHCHECK_INTERVAL` | integer-string | spec | Sampling interval in seconds |
| `HEALTH_STATUS` | enum | runtime | `healthy`, `starting`, `degraded`, `unhealthy`, or `unknown` |
| `LAST_HEALTH_AT` | timestamp | runtime | Last successful health evaluation timestamp or `''` before first sample |
| `CPU_ALERT_PCT` | integer-string | spec | CPU threshold in percent |
| `MEM_ALERT_MB` | integer-string | spec | Memory threshold in MB |
| `NET_ALERT_MBPS` | integer-string | spec | Network threshold in MB/s |
| `ALERT_EMAIL` | enum | spec | `yes` or `no` |
| `STATUS` | enum | runtime | Docker runtime state such as `created`, `running`, `restarting`, `paused`, `exited`, `dead`, or `unknown` |
| `CREATED` | timestamp | runtime | Record creation time |
| `UPDATED` | timestamp | runtime | Last metadata update time |

### Canonical Persisted Example

```bash
NAME='app' CTN_NAME='vx-jack-app' OWNER='jack' IMAGE='ghcr.io/example/app:latest' COMMAND='' \
ENV='PORT=3000||NODE_ENV=production' MOUNTS='data:/srv/app/data||config:/srv/app/config' \
HOST_PORT='21001' CONTAINER_PORT='3000' DOMAIN='app.example.com' ROUTE_PATH='' \
PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:21001' AUTO_START='yes' \
RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='http' \
HEALTHCHECK_TARGET='http://127.0.0.1:21001/health' HEALTHCHECK_INTERVAL='60' \
HEALTH_STATUS='healthy' LAST_HEALTH_AT='2026-06-27 14:00:00' \
CPU_ALERT_PCT='85' MEM_ALERT_MB='1024' NET_ALERT_MBPS='50' ALERT_EMAIL='yes' \
STATUS='running' CREATED='2026-06-27 14:00:00' UPDATED='2026-06-27 14:05:00'
```

## Defaulting Rules

- `COMMAND`, `ENV`, `MOUNTS`, `DOMAIN`, and `ROUTE_PATH` default to empty strings.
- `AUTO_START` defaults to `yes`.
- `RESTART_POLICY` defaults to `unless-stopped`.
- `HEALTHCHECK_TYPE` defaults to `http`.
- `HEALTHCHECK_TARGET` defaults to `http://127.0.0.1:<CONTAINER_PORT>/health` when `HEALTHCHECK_TYPE='http'`.
- `HEALTHCHECK_INTERVAL` defaults to `60`.
- `CPU_ALERT_PCT` defaults to `85`.
- `MEM_ALERT_MB` defaults to `1024`.
- `NET_ALERT_MBPS` defaults to `50`.
- `ALERT_EMAIL` defaults to `yes`.
- `PROXY_MODE`, `PROXY_TARGET`, `HEALTH_STATUS`, `LAST_HEALTH_AT`, `STATUS`, `CREATED`, and `UPDATED` are persisted runtime fields and are never accepted as create/update spec inputs.

## Cross-Field Rules

- `DOMAIN=''` requires `ROUTE_PATH=''`, `PROXY_MODE=''`, and `PROXY_TARGET=''`.
- `DOMAIN!=''` requires `PROXY_MODE='proxy'` and `PROXY_TARGET='http://127.0.0.1:<HOST_PORT>'`.
- `HEALTHCHECK_TYPE='none'` requires `HEALTHCHECK_TARGET=''`.
- `HEALTHCHECK_TYPE='docker'` allows `HEALTHCHECK_TARGET=''`.
- `HEALTHCHECK_TYPE='http'` or `tcp` requires non-empty `HEALTHCHECK_TARGET`.
- `ALERT_EMAIL='no'` suppresses fan-out to Vesta notifications but does not suppress alert record creation in `docker-alerts.conf`.

## Mutation Rules

- `bin/v-add-docker-container` must reject unknown keys.
- `bin/v-change-docker-container` must preserve derived fields not present in the update spec unless the implementation explicitly recomputes them.
- Persisted records must remain single-line Vesta records so list/read helpers can reuse existing config-file parsing patterns.
