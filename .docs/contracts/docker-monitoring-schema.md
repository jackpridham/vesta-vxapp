# Docker Monitoring Schema Contract

## Scope

This contract defines:

- the runtime RRD file naming convention
- datasource names and units
- the JSON response shape used by the web UI for live cards and charts
- the polling cadence for live versus historical Docker metrics

## RRD Naming And Datasources

Each managed container has exactly one RRD file at:

```text
$RRD/docker/<user>_<name>.rrd
```

The RRD must contain these exact datasources:

```text
DS:CPU:GAUGE
DS:MEM:GAUGE
DS:RX:DERIVE
DS:TX:DERIVE
```

### Unit Contract

| Datasource | Stored unit | UI unit | Notes |
| --- | --- | --- | --- |
| `CPU` | percent | percent | maps to `CPU_PCT` and `LATEST.CPU_PCT` |
| `MEM` | megabytes | megabytes | maps to `MEM_MB` and `LATEST.MEM_MB` |
| `RX` | bytes per sample interval, derived to rate | MB/s | maps to `RX_MBPS` and `LATEST.RX_MBPS` |
| `TX` | bytes per sample interval, derived to rate | MB/s | maps to `TX_MBPS` and `LATEST.TX_MBPS` |

## JSON Response Contract

All web-facing stats endpoints for Docker live charts and dashboard cards must return this exact top-level shape.

```json
{
  "OWNER": "jack",
  "NAME": "app",
  "PERIOD": "5m",
  "CPU_PCT": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 12.4}],
  "MEM_MB": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 384}],
  "RX_MBPS": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 1.2}],
  "TX_MBPS": [{"TS": "2026-06-27T14:00:00Z", "VALUE": 0.6}],
  "LATEST": {"CPU_PCT": 12.4, "MEM_MB": 384, "RX_MBPS": 1.2, "TX_MBPS": 0.6}
}
```

### Field Rules

| Field | Type | Validation |
| --- | --- | --- |
| `OWNER` | string | owner username from metadata |
| `NAME` | string | logical container name from metadata |
| `PERIOD` | enum-string | requested rollup window; first implementation supports at least `5m`, `1h`, `1d`, `7d` |
| `CPU_PCT` | array | ordered oldest to newest; entries use `TS` and `VALUE` only |
| `MEM_MB` | array | ordered oldest to newest; entries use `TS` and `VALUE` only |
| `RX_MBPS` | array | ordered oldest to newest; entries use `TS` and `VALUE` only |
| `TX_MBPS` | array | ordered oldest to newest; entries use `TS` and `VALUE` only |
| `LATEST` | object | always contains `CPU_PCT`, `MEM_MB`, `RX_MBPS`, `TX_MBPS` |
| `TS` | string | RFC 3339 UTC timestamp, for example `2026-06-27T14:00:00Z` |
| `VALUE` | number | numeric JSON value, not a quoted string |

## Sampling Rules

- Producers sample CPU, memory, RX, and TX from `docker stats --no-stream`.
- The RRD update job is the source of truth for historical charts.
- Web JSON responses may return the most recent live sample even when the corresponding history graph image has not been regenerated yet.

## Polling Contract

Define "live" exactly as follows:

- chart cards poll JSON endpoints every `60` seconds
- edit-page metric panels refresh every `30` seconds while the page is open
- RRD-backed history charts may lag one sampling interval behind the latest dashboard card values

## UI Mapping

| JSON field | List dashboard card | Edit-page chart container |
| --- | --- | --- |
| `LATEST.CPU_PCT` | `docker-card-cpu` | `docker-chart-cpu` |
| `LATEST.MEM_MB` | `docker-card-mem` | `docker-chart-mem` |
| `LATEST.RX_MBPS` | `docker-card-rx` | `docker-chart-rx` |
| `LATEST.TX_MBPS` | `docker-card-tx` | `docker-chart-tx` |

## Failure Contract

When stats are temporarily unavailable:

- the endpoint must keep the same top-level field names
- metric arrays may be empty arrays
- `LATEST` values may be `null`
- callers must not infer alternate keys or alternate units
