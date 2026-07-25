# Docker Alerts And Health Schema Contract

> **Historical contract (superseded 2026-07-25):** This schema applies to
> direct-container alerts. Compose project/service alert behavior is governed
> by the [current plan](../plans/2026-07-25-compose-orchestration.md) and
> [security contract](compose-security.md).

## Scope

This contract defines:

- the persisted alert record format in `data/users/<user>/docker-alerts.conf`
- the allowed Docker health statuses
- severity mapping onto the existing Vesta user-notification surface

## Persisted Alert File

- Path: `data/users/<user>/docker-alerts.conf`
- Encoding: ASCII
- Record format: one Vesta-style shell assignment record per line
- Primary key: `AID`
- Records are append-or-update entries for managed Docker alerts; acknowledging an alert changes `ACK`, not `AID`

## Alert Record Shape

Persisted alert records must use this exact shape:

```bash
AID='1' NAME='app' OWNER='jack' LEVEL='warning' TYPE='health' STATUS='open' \
TITLE='Health check failing' MESSAGE='GET /health returned 500 three times' \
STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'
```

### Alert Fields

| Field | Type | Allowed values / meaning |
| --- | --- | --- |
| `AID` | integer-string | monotonically increasing per user alert file |
| `NAME` | string | logical container name |
| `OWNER` | string | Vesta username that owns the container |
| `LEVEL` | enum | `warning`, `critical`, `info` |
| `TYPE` | enum | `health`, `cpu`, `memory`, `network` |
| `STATUS` | enum | `open`, `closed` |
| `TITLE` | string | short operator-facing summary |
| `MESSAGE` | string | detailed event text shown in the panel |
| `STARTED` | timestamp | first time the alert opened |
| `LAST_SEEN` | timestamp | last sample that still matched the alert condition |
| `ACK` | enum | `yes`, `no` |

## Health Status Vocabulary

Allowed health statuses are:

```text
healthy
starting
degraded
unhealthy
unknown
```

### Health Status Meaning

| Status | Meaning |
| --- | --- |
| `healthy` | the container and any configured health target are passing |
| `starting` | Docker reports a start-up health phase and the result is not final yet |
| `degraded` | the container is running but explicit health checks are intermittently failing |
| `unhealthy` | Docker health or explicit health checks are persistently failing |
| `unknown` | no Docker-native health result and no explicit target result is available |

## Alert Trigger Rules

Alert producers open or refresh an alert record when any of the following is true:

- `HEALTH_STATUS='degraded'`
- `HEALTH_STATUS='unhealthy'`
- sampled CPU exceeds `CPU_ALERT_PCT`
- sampled memory exceeds `MEM_ALERT_MB`
- sampled RX or TX exceeds `NET_ALERT_MBPS`

Alerts close when the sampled condition no longer exceeds the contracted threshold or health state returns to `healthy`.

## Severity Mapping To Existing Vesta Notifications

The existing Vesta notification surface is `bin/v-add-user-notification USER TOPIC NOTICE [TYPE]`, persisted in `notifications.conf` with `TOPIC`, `NOTICE`, and `TYPE`.

Docker alert fan-out must map `LEVEL` onto that surface as follows:

| Alert condition | `LEVEL` | Notification `TOPIC` pattern | Notification `NOTICE` | Notification `TYPE` |
| --- | --- | --- | --- | --- |
| `HEALTH_STATUS='degraded'` | `warning` | `Docker alert: <name> degraded` | `/list/docker/` | `warning` |
| `HEALTH_STATUS='unhealthy'` | `critical` | `Docker alert: <name> unhealthy` | `/list/docker/` | `error` |
| CPU threshold breach | `warning` | `Docker alert: <name> CPU high` | `/list/docker/` | `warning` |
| Memory threshold breach | `warning` | `Docker alert: <name> memory high` | `/list/docker/` | `warning` |
| Network threshold breach | `warning` | `Docker alert: <name> network high` | `/list/docker/` | `warning` |

### Notification Constraints

- Fan-out only occurs when `ALERT_EMAIL='yes'`.
- Persisting an alert record in `docker-alerts.conf` does not depend on notifications being enabled.
- Closing or acknowledging a Docker alert does not delete the matching Vesta notification entry.
- `ACK='yes'` only affects the Docker alert record state and panel rendering.

## Ownership And Access Rules

- `data/users/<user>/docker-alerts.conf` stores only alerts for that `<user>`.
- Admins may read another user's Docker alerts through owner-qualified commands.
- Regular users may acknowledge only alerts whose `OWNER` matches the logged-in user.
