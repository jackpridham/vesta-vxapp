# Compose Networking and Route Contract

## Bridge networking

`standard` and `admin-approved` projects receive project-scoped Compose
networks. External networks, macvlan/ipvlan, static host interface
manipulation, and cross-project network attachment are rejected. Workloads may
have no published ports.

Published ports support:

- TCP or UDP;
- multiple mappings;
- matching port ranges;
- explicit IPv4 localhost binding;
- explicit approved public binding;
- no binding for internal-only services.

The host IP must be explicit: omitted or unsupported addresses are rejected.
Port conflicts are checked against Vesta metadata and live listeners while
holding the project lock and the host-wide port-allocation lock.

## Host networking

Host mode is rejected for every profile. Administrator-approved projects
remain bridge-only and must use explicit validated port publications.

## HTTP routes

HTTP routing remains Vesta-owned state:

- route owner must equal project owner;
- domain must exist in the owner's `web.conf`;
- route selects project, service, container port, scheme, and optional path;
- the target is a localhost published port;
- `vx-proxy` remains the renderer;
- non-HTTP services do not receive nginx configuration.

Route changes are staged per project and applied by a start-like lifecycle
operation. Candidate health must pass before nginx state changes; nginx config
test, reload, and a bounded Host-header probe through the domain's local Vesta
IP must pass before active route metadata commits. Rollback restores the
previous Vesta route metadata and nginx output.

## Native ingress consumers

The read-only native ingress reverse index scans Vesta `web.conf` authority
with the non-eval parser. It accepts only `vx-proxy` HTTP(S) backend targets
that exactly match a validated TCP published endpoint. It never reloads nginx
or changes route state.

Administrator output contains the consumer owner, domain, public scheme,
path, normalized backend target, bounded backend health, rendered-config
freshness, and proxy header names. Header values are discarded before output
and are never compared, retained, hashed, logged, or included in diagnostic
metadata. The optional actor is passed only from a server-derived authenticated
panel identity; missing or ordinary-owner actors receive only the consumer
count. The adapter never infers panel authority from `root`, `sudo`, or other
OS process identity. An explicit administrator actor receives full redacted
records, and a non-administrator receives them only when the project-role
capability contract reports a real `view-ingress-consumers` grant.

## Validation

Tests cover multiple TCP/UDP ports, ranges, localhost, no-port projects,
duplicate/conflicting ports, forbidden public binds, bridge isolation,
host-mode rejection, HTTP route
ownership, and route rollback.
