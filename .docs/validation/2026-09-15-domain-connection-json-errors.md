# Domain-connection JSON error transport acceptance

Native correction: repository issue #9.
Consumer dependency: downstream issue #320 (B2), linked from issue #9.

Implementation: `7f2c60aa4946ae23b99236ff59903c7465535514`.
Tested release: `e02ebeab8a15f9336a7d15e9ebdc6330f02081da` on the owner-confirmed
`feat/domain-connection-lifecycle` branch. The latter commit only makes the
transport fixture runnable from installed Vesta trees.

## Review and correction

The create adapter converted native conflict/quota/disabled outcomes to process
statuses 4/8/11, then emitted identical error prose. The authenticated HTTP
output handler discarded the status. JSON create failures now carry the
[versioned error envelope](../contracts/domain-connections.md#create-errors-over-the-authenticated-http-api)
without changing the upstream HTTP handler or the success envelope.

Review also found that unreadable quota/enrollment authority could resemble a
known quota/disabled condition. The shared helpers now distinguish a false
condition from a failed read; the adapter retains the legacy process status
while emitting `native_failure`. Consumers must classify the version/code/status
pair, not infer a condition from `exitCode` alone.

## Controlled authenticated HTTP artifacts

Each artifact is the body of an actual HTTP 200 response from the unchanged
`web/api/index.php` in output mode:

```json
{"version":1,"error":{"code":"hostname_conflict","exitCode":4}}
{"version":1,"error":{"code":"quota_exceeded","exitCode":8}}
{"version":1,"error":{"code":"enrollment_disabled","exitCode":11}}
```

Invalid input and unsafe authority return `native_failure` with status 2.
Malformed enrollment authority returns `native_failure` with status 11;
unreadable quota returns `native_failure` with status 8. Strict response equality
checks reject extra fields, prose, owner/reservation identity, or proof leakage.

Run `bash test/domain-connections/test-http-errors.sh`. The fixture uses private
mount and network namespaces, loopback HTTP, a synthetic API key, the real
`v-check-api-key`, the shipped create adapter and native registry. It substitutes
managed-provider evidence and a sudo dispatcher that records the **actual**
child exit status. It never injects a result code. Every accepted request asserts
one authentication invocation and exactly one mutation invocation; invalid
authentication invokes neither command. It makes no live provider/customer calls.

The same harness proves:

- connection identity, generation, and quota in the success envelope;
- idempotent replay, including after enrollment is disabled;
- shell failure prose and process statuses unchanged;
- `returncode=yes` returning status only, including successful replay;
- invalid and unknown failures remaining unclassified.

The existing `test/domain-connections/test-state.sh` also passed its state,
concurrency, ownership, quota, recovery, worker, and cached-adapter checks.
Touched Bash syntax, unchanged HTTP-handler PHP lint, and whitespace checks pass.

## Consumer handoff

The native artifact is published on the confirmed Vesta branch. The API owner
must consume the documented envelope and finish B2 transport acceptance on
`release-301-pre-mfa-system-email`. No API branch history, source, migrations,
runtime, customer DNS, or enrollment settings were changed for this correction.
Publishing this native evidence does not claim completion of API #320.

## Release validation and deployment

The required limited launcher passed on documentation successor `8d161859`
from 2026-09-15 05:34:18 to 05:42:59 UTC. Runtime and fixture bytes match `e02ebeab`.
CPU was capped at 100%; memory, swap, task and nice limits remained enforced;
no unlimited override was used. The canonical gate ran unchanged. Its root-only
disposable-container fixture reported its normal explicit skip. The earlier
run stopped at documentation consistency; the portable handoff references were
corrected before the successful repeat.

Development installed `e02ebeab`: three source files and three release markers,
with all 140 source paths plus three markers verified independently. The
installed isolated authenticated HTTP suite passed, and locked installation
acceptance preserved native authority, services, workloads and enrollment.
Protected exact-file rollback and private host evidence are retained.

Staging also installed `e02ebeab` after the operator explicitly authorized the
file-only update while preserving its existing unrelated workload recovery.
All 140 source paths and three identity markers verify, and the installed
isolated authenticated HTTP suite passes. Final before/after observations are
identical across 39 authority files, 11 containers, service identities, native
routes, the enabled/active mount guard, and the retained recovery file. No
workload recovery, restart, enrollment enablement, or migration was performed.
Temporary release inputs were removed and all rollback sets retained and verified.
