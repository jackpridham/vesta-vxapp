# compatibility host cron backup compatibility validation

Date: 2026-08-16 AEST
Target: `<compatibility-host>` (compatibility host)
Plan: `.docs/plans/2026-08-16-legacy-container-backup-compatibility.md`

## Release

- `e87ca63e fix(web): make backup notifications PHP 8.4 safe`
- `ea4d4b99 fix(compose): preserve accepted secret mount authority`
- `395ed209 fix(compose): recover legacy disabled secrets`
- The constrained `test/compose/run-production-readiness-limited.sh` release
  gate passed after the final change.
- The installed `runtime-secrets.py` SHA-256 is
  `478419a3f8a0285010e4c8a84709a0d82dd9e9f86c0c92e94b6c9b5352ba52bd`.

## Recovery and acceptance

The first targeted backup exposed an older accepted compatibility workload revision whose
empty `maxotel-creds` value is an intentional carrier-disabled sentinel. Its
private integrity metadata has bound the empty SHA-256 since installation.
New secret creation and bundle import continue to reject empty inputs; the
runtime helper now accepts only a grandfathered zero-byte value with the exact
protected empty-digest record and fails closed for missing or mismatched
integrity.

The exact stopped revision-1 container was restored while the recovery marker
remained authoritative. After installing the reviewed helper, Vesta's locked
backup recovery recreated the workload, waited for health, recorded
`backup-recovery succeeded`, and removed the marker. No image, revision,
secret value, route, or unrelated container was changed.

Acceptance evidence:

- `v-backup-user compatuser` exited successfully and produced a validated
  7 MB archive.
- The exact cron path, `v-backup-users`, exited successfully for all 10 active
  users.
- `/usr/local/vesta/data/df/backup-success.txt` is present and
  `backup-error.txt` is absent.
- The current backup log contains 10 successful-user records and no PHP
  deprecation/warning/undefined-key or Compose project backup failure.
- `compatuser/app` remains revision 1, `running`, `healthy`, `fresh`, with zero
  restarts and no backup recovery marker.
- Mount comparison is clean. The only remaining drift is the known pre-existing
  approved host-network compatibility difference, outside this repair.
- `cron`, Docker, nginx, Dovecot, and Exim are active; `nginx -t` and
  `doveconf -n` pass.
- The root filesystem is 31% used with 102 GB available; `/tmp` is 1% used.

## Rollback and retained space recovery

- Pre-install runtime files are retained at
  `/root/vesta-backups/pre-cron-backup-compatibility.Alezg4Pi` on compatibility host.
- Two stale Harbor working directories moved during capacity recovery remain
  recoverable below `/var/tmp/codex-recoverable-20260816`, outside live Vesta
  and registry data.
