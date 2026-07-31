# Compose Operator Controls Contract

## Project roles

Standard projects may store explicit assignments in root-owned mode-`0600`
`roles.json`. The only roles are `viewer`, `operator`, `deployer`,
`backup-operator`, and `secret-manager`. Their capabilities are:

| Role | Capabilities |
| --- | --- |
| viewer | view |
| operator | view, lifecycle, reconcile |
| deployer | view, preview, deploy, rollback |
| backup-operator | view, backup, restore |
| secret-manager | view, secret |

Owner and administrator authority remains implicit. Only the owner or
administrator manages assignments. Delegation never changes project ownership
or profile authority, applies only to `standard`, and is denied immediately
when revoked or when the actor is missing or suspended. Unknown roles fail
closed. CLI and AJAX mutations call the same capability helper before any
mutation.

## Typed operations

Long-running actor-aware actions persist mode-`0600`
`runtime/last-operation.json` with:

`OPERATION_ID`, `ACTOR`, `ACTION`, `STARTED`, `UPDATED`, `FINISHED`, `PHASE`,
`PERCENT`, `RESULT`, `CURRENT_REVISION`, `TARGET_REVISION`, and a bounded
redacted `MESSAGE`.

The identifier is opaque lowercase hexadecimal. A running typed operation owns
the record; nested lifecycle audit events cannot replace it. Spawned panel
output emits the identifier, bounded phase/percent transitions, and the final
result.

## Revision and rollback previews

Revision comparison verifies both immutable revision manifests before
returning service add/remove/change facts, endpoint/image/resource/security
changes, route effects, and redacted definition counts/names. A rollback
preview binds:

- current and target revision;
- SHA-256 of both revision manifests;
- definition, runtime, route, data, backup, and secret-reference impact.

Apply re-authorizes and regenerates those facts under the project lock.
Changed current revision or either changed manifest is stale and fails before
runtime mutation.

## Drift evidence and reconcile

Drift evidence schema 1 compares desired canonical/revision authority with
ownership-verified Docker inspection. The stable evidence set is:

- service presence;
- `vx.managed`, owner, project, and revision labels;
- accepted image identity and image label;
- normalized Compose networks;
- normalized mount source, target, and read-only state;
- published IP/host/container port and protocol;
- privileged, capabilities, network/PID/IPC mode, and devices;
- desired-running versus observed container state.

Container IDs/names, timestamps, health output, restart count, runtime IP/MAC
addresses, endpoint IDs, resource counters, and log paths are excluded as
volatile. Sorted stable evidence is SHA-256 digested. Reconcile is never
automatic: it requires `reconcile`, CSRF in the panel, current revision and
the exact observed digest. The evidence is re-observed under the project lock;
stale or failed inspection is denied before normal deploy/health/route
convergence and rollback behavior.

## Notifications

Notification routes accept only the types `health`, `quota`, `backup`, and
`deployment`, and only approved destinations `panel` and `account-email`.
No URL, token, endpoint, credential, or arbitrary command is accepted in
public metadata. Delivery attempts every configured destination and reports a
partial failure without exposing alert secrets.
