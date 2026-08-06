# Container Orchestration Architecture and Operator Guide

## Scope

The Vortex Docker orchestrator is a single-host Docker Compose control plane
inside Vesta. Compose owns workload desired state; Vesta owns authorization,
policy, stable storage, routes, backup and restore, monitoring, audit, and the
panel workflow.

The implementation supports tenant-owned `standard` projects and expiring
administrator-approved projects. It does not provide Kubernetes, Swarm,
multi-node scheduling, host networking, host firewall mutation, Docker socket
mounts, privileged workloads, arbitrary host paths, host PID or IPC, devices,
or global Docker cleanup.

## Authority and storage

Desired state is stored at:

```text
/usr/local/vesta/data/users/<user>/docker-projects/<project>/compose.yaml
```

The control root also holds immutable revisions, canonical definitions, image
evidence, routes, audit records, operation state, and managed secrets. Durable
bind data lives under `/home/<user>/docker/<project>/binds/`; named volumes
use the `vx_<user>_<project>_<volume>` convention. Docker objects and inspect
output are runtime evidence, not authority.

Runtime project identity is always `vx-<user>-<project>`. Every read or
mutation resolves the actor, owner, project, profile, and ownership labels
before acting.

## Policy

Definitions are canonicalized with `docker compose config --format json` in
a controlled environment, then evaluated by a deny-first policy. The policy
rejects privileged mode, Docker and container-runtime sockets, host
networking, host PID or IPC, devices, unsafe capabilities, arbitrary host
paths, and unapproved security options.

Ordinary users can create and update only their own `standard` projects.
Administrator profile assignments are explicit, expiring Vesta state.
Ownership labels are verified before runtime mutation.

## Networking and ingress

Projects use managed bridge networks. Published ports are checked under the
global port lock and must satisfy the selected profile. HTTP ingress is
declared in Vesta route state and rendered through the `vx-proxy` template;
projects without routes produce no nginx configuration.

Cross-owner native web-domain proxies remain in their native Vesta domain
authority. Compose may expose only redacted consumer metadata and header
names.

## Images and secrets

Image evidence binds the accepted image ID, immutable registry digest,
platform, profile version, policy version, and trust decision. Trust adapters
run from fixed root-owned paths with an empty environment, immutable inputs,
and bounded redacted output.

Registry credentials and secret values never appear in argv, metadata,
environment, logs, UI, audit, or unencrypted backups. Managed secrets are
root-owned mode-0600 files and public reads expose metadata only.

## Lifecycle and transactions

Shared behavior lives in `func/vx/compose/*.sh`; commands under `bin/` are
thin Vesta adapters. Project locks cover revision checks, deployment,
convergence, route application, and rollback. Candidate updates are staged in
protected state, validated, converged, and committed atomically. Failed
updates restore the prior accepted revision or leave an explicit
restore-required state.

Self-service preview is non-mutating. Apply accepts only the server-issued
preview token and owner/project/profile facts, verifies expiry, digests,
ownership, and expected revision, then holds the project lock through
convergence or rollback.

## Backup and restore

Backups include definitions, revisions, image evidence, managed routes, bind
data, named volumes, audit state, and encrypted secret payloads when
configured. Project data is retained by default. Restore validates archive
authority before mutation and verifies runtime identity, health, networks,
volumes, and routes before clearing recovery state.

The orchestrator never runs global Docker prune or broad cleanup.

## Panel integration

The Docker panel uses the same CLI contracts as the shell surface. POST and
AJAX mutations retain authentication and CSRF checks, shell arguments are
escaped, and asynchronous work runs through the bounded job mechanism.
Ordinary users receive only their own standard-project controls; privileged
operations remain administrator-only.

## Primary commands

```text
v-add-docker-project USER PROJECT COMPOSE_FILE [PROFILE]
v-validate-docker-project USER PROJECT [json]
v-deploy-docker-project USER PROJECT
v-list-docker-projects USER [FORMAT]
v-list-docker-project USER PROJECT [FORMAT]
v-start-docker-project USER PROJECT
v-stop-docker-project USER PROJECT
v-restart-docker-project USER PROJECT
v-recreate-docker-project USER PROJECT [SERVICE]
v-change-docker-project USER PROJECT COMPOSE_FILE
v-rollback-docker-project USER PROJECT [REVISION]
v-delete-docker-project USER PROJECT [keep-data]
```

Supporting commands cover health, logs, metrics, alerts, audit, routes,
images, registries, secrets, backup, restore, adoption, migration, and web
source handling. The complete command surface is documented in
[Compose interfaces](../.docs/contracts/compose-interfaces.md).

## Validation

Run focused shell suites for every changed contract, syntax-check all touched
Bash, PHP, and JavaScript, render affected fixtures through Compose, run the
native reverse-proxy tests when route or vhost behavior changes, and finish
with:

```text
test/compose/run-production-readiness.sh
git diff --check
```
