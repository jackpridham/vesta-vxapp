# Native Web-Domain Proxy Dev-Host Validation

- **Validation date:** 2026-08-06
- **Authorized host:** `operator@192.0.2.10` (`development.example.com`)
- **Authorized domain:** `admin/app.example.com`
- **Initial candidate:** `3fdd617d12ebe903a7480d405e17a1a262717abc`
- **Validated successor:** `a357eb6649979130c71752b24cdf79cece98032a`
- **Runtime version:** `0.9.9-0-16+vxapp.a357eb66`
- **Runtime build date:** `2026-08-06T09:20:46Z`
- **Outcome:** all CLI, authenticated panel, state, render, HTTP, ACME
  staging, HTTPS, renewal, rebuild, disable, restoration, authentication
  restoration, and cleanup gates passed.

## Authorization and boundaries

The user replaced the original staging staging target with the dev server and
explicitly authorized deployment and testing against `app.example.com`.
No production host was accessed. No Docker/Compose workload, tenant domain,
firewall, DNS record, or WAN route was changed. The existing
`X-Business-GUID` value was captured only inside a mode-0700 root snapshot; it
was never printed, copied into documentation, or used by the echo service.

## Candidate deployment and rollback

The dev host initially reported runtime `1aca8895...`, Vesta held, active
Nginx/Apache/Vesta services, and a passing `nginx -t` with
`ulimit -n 65535`. The existing domain was an SSL/Let's Encrypt native proxy
to loopback port 8420 with the application profile, preserved Host, timeout
60, and the `X-Business-GUID` header name.

An additive overlay installed 1,232 regular files from committed `bin/`,
`func/`, and `web/`, plus the two installed `vx-proxy` Nginx templates. It did
not use `--delete` and did not write under `data/users`. The transaction held
`/run/lock/vesta-vxapp-release.lock`, installed root-owned content, retained
before/after hashes and absent-path evidence, and passed targeted Bash/PHP
syntax, `nginx -t`, `apache2ctl configtest`, and service checks.

The protected deployment rollback is:

```text
/root/vesta-backups/pre-native-web-proxy-20260806T080925Z-1aca8895
```

It is mode 0700, root-owned, and includes the pre-deployment runtime marker,
version, build date, exact prior files, absent paths, payload hash, and
before/after hashes. The domain lifecycle snapshot is likewise root-owned and
mode 0700:

```text
/root/vesta-backups/native-web-proxy-domain-20260806T081108Z
```

That snapshot protects the exact domain record, production ACME account,
cron authority, certificate/key/chain, domain renders, `public_html`, metadata,
hashes, and baseline HTTP/HTTPS bodies.

The later real-create remediation used a separate comprehensive mode-0700,
root-owned rollback:

```text
/root/vesta-backups/native-web-proxy-create-20260806T090216Z
```

Its 2,211 file hashes and metadata cover the complete administrator
web/user/cron authority, SSL and ACME files, IP counters, entire domain tree,
all administrator render files and symlinks, aggregate Apache/Nginx authority,
domain logs, matching PHP pools, and baseline bodies. Restoration was scoped
to the exact paths affected by public delete/create commands; unrelated live
logs and other domains were not overwritten from the broader rollback.

The first overlay transaction was rejected locally by the command safety
filter before transfer. A corrected transaction then stopped before its
install boundary because its generated manifest was mistakenly placed inside
the staged tree. Reconciliation proved the runtime and domain were unchanged;
only those exact incomplete artifacts were removed before the successful
transaction. The release also initially stamped `version.txt` without
stamping `conf/vortex-vesta-fork-commit`; the old full marker was added to the
protected rollback before the exact candidate marker was installed.

The repository tracks 91 older Vesta `bin/` helpers without an executable bit,
including `v-restart-proxy`, while the installed command contract requires
them executable. The initial overlay therefore caused the first proxy-disable
attempt to clear state and then fail at restart. All 570 installed public
commands were restored to root-owned mode 0755 from the established runtime
mode contract, and the failed attempt was preserved in evidence.

## Lifecycle results

An isolated Python echo service listened only on `127.0.0.1:18420`. It logged
request paths, forwarded-header facts, and a Boolean disposable-GUID match; it
never logged a GUID value.

- **Real CLI create:** Earlier preliminary evidence used a
  disable-then-change create-equivalent because the authorized domain already
  existed; that did not prove the documented public create adapter. The final
  remediation first verified the domain had no aliases, FTP users, stats, or
  backend object, took the comprehensive rollback above, and removed only the
  exact web-domain object through `v-delete-web-domain`. It then executed the
  real documented `v-add-web-domain` form with administrator, domain, staging
  IP, `no`, `none`, an empty extension argument, and the exact
  `--proxy-target`, `--proxy-mode`, `--proxy-profile`,
  `--proxy-preserve-host`, `--proxy-timeout`, and `--header` options. List
  JSON, `web.conf`, and generated HTTP/SSL `vx-proxy` renders agreed on the
  target, profile, timeout, and disposable header. `nginx -t`, reload, and an
  HTTP request proved path/query, Host, every expected `X-Forwarded-*` fact,
  and the disposable GUID at the echo backend. The disposable created object
  was supported-deleted before exact scoped restoration. The original record,
  all affected hashes, production certificate fingerprint, baseline HTTP and
  HTTPS bodies, services, and original port-8420 listener were exact. The
  already-approved ACME issuance/renewal lifecycle below was not repeated.
  An earlier command attempt in the preliminary lifecycle lacked exported
  `VESTA` and failed before mutation.
- **Issuance:** The production-bound ACME KID was protected and temporarily
  removed so `LE_STAGING=yes v-add-letsencrypt-domain` could register against
  the staging directory. Real HTTP-01 issuance succeeded. No challenge
  request reached the backend. State remained `SSL='yes'` and
  `LETSENCRYPT='yes'`; certificate files, cron renewal authority, staging
  issuer, matching SAN, SSL render, Nginx, SNI, HTTPS forwarding, and the
  disposable GUID all passed. The render correctly referenced Vesta's
  combined `.pem`; an initial evidence assertion incorrectly expected `.crt`
  and was corrected.
- **CLI edit:** A disposable header change through
  `v-change-web-domain-proxy-options` replaced the old value in state and both
  renders, and the backend matched the new value.
- **Authenticated panel:** The first Playwright attempt used the existing
  mode-0600 local environment file against
  `https://192.0.2.10:8083`; those credentials were not valid on this
  server, so it stopped at login without loading or saving the form. The user
  then explicitly authorized a temporary, reversible dev-only administrator
  password rotation. Before rotation, a root-only snapshot captured the exact
  `admin` shadow line, shadow metadata, `user.conf`, and the session inventory
  reported by PHP CLI. The live panel used Vesta's separate
  `/usr/local/vesta/data/sessions` path; the browser's exact session identifier
  was therefore captured directly and only that validated file was removed.
  `chpasswd` received a one-time password only through stdin; the password was
  never placed in argv, environment, output, logs, evidence, or repository
  files. The public password command was deliberately not used, so RKEY and
  `user.conf` remained byte-identical. Real Chromium authentication then
  loaded the edit page, verified Proxy Support, target, profile,
  preserve-Host, timeout, and one protected `X-Business-GUID` value, submitted
  a new disposable header through the real CSRF form, and reloaded the saved
  value. `web.conf`, both renders, Nginx, and the redacting echo backend agreed
  on the change. The exact Vesta PHP session was removed. An
  `lckpwdf`-protected atomic replacement restored only the original admin
  shadow line while preserving every other current shadow entry. A final real
  panel login rejected the one-time password, its failed-login session was
  removed, the original shadow line matched exactly, and `user.conf`/RKEY
  remained unchanged. Temporary password and browser-state files were
  destroyed. Two earlier rejection verifiers were retained as failed attempts:
  Python lacked its optional `crypt` module, and Unix `su` was not a valid
  login surface for this panel-only administrator. The latter attempt was
  detected while its fresh temporary shadow was active and triggered an
  immediate exact restoration before the successful panel-native rejection
  proof.
- **Rebuild:** The repository has the canonical public
  `v-rebuild-web-domains`, not a singular `v-rebuild-web-domain`. The
  administrator rebuild preserved the complete `web.conf` byte-for-byte,
  native state, both renders, SSL/Let's Encrypt, Nginx, and HTTPS. It emitted a
  pre-existing missing `PHP-FPM-82` template warning for another derived
  administrator render; the target remained valid and no domain authority
  changed.
- **Renewal:** Eight Let's Encrypt domains were inspected and no unrelated
  certificate was inside the renewal window. A one-day SAN-matching fixture
  was installed through `v-change-web-domain-sslcert`. The actual
  `LE_STAGING=yes v-update-letsencrypt-ssl` path replaced its SHA-256
  fingerprint with a new staging certificate. SAN, SSL/Let's Encrypt, native
  proxy/header state, Nginx, HTTPS, and no-ACME-forwarding all passed.
- **Disable:** The original `v-delete-web-domain-proxy` removed the Nginx
  frontend; HTTP initially returned 404, and a rebuild restored HTTP but left
  HTTPS at 404. This was a product blocker, not accepted as a deviation.
  Successor `7beba3ca` restores the owner's ordinary `hosting` frontend when
  deleting `vx-proxy`, while clearing native mode, target, profile,
  preserve-host, timeout, header, and path fields. The direct public command,
  with no follow-up rebuild, then served the `public_html` marker over HTTP
  and HTTPS, preserved SSL/Let's Encrypt, and did not reach the backend.

The successor changed only `bin/v-delete-web-domain-proxy` and its focused
test. `bash -n`, `bash test/test_web_domain_proxy.sh`,
`php test/test_web_proxy_form.php`, and `git diff --check` passed before its
one-file runtime promotion. The live marker, version, and build date were
advanced atomically under the existing release lock.

## Final-review authority parsing correction

Final code review found that native target validation did not validate an
explicit port and that the Host-header helper reduced a bracketed IPv6 target
to a single `[`. Commit `a357eb6649979130c71752b24cdf79cece98032a` closes
that release blocker with one shared HTTP(S) authority parser in
`func/vx/proxy.sh`. It requires a host, accepts ordinary hostname/IPv4 and
bracketed IPv6 authorities, retains the existing path/query behavior, rejects
unbracketed IPv6 and malformed brackets, and rejects empty, nonnumeric, zero,
or greater-than-65535 explicit ports. No catalog, approval, or policy layer
was added. Focused tests cover loopback, HTTPS, bracketed IPv6, Host rendering,
all required invalid port classes, oversized numeric input, and malformed
brackets.

Only the committed helper was promoted to the authorized dev host under
`/run/lock/vesta-vxapp-release.lock`. Its deployed SHA-256 is
`1ea77efd1e64bf039b2087f47c02d06c05cc5ba91cb040190ba0886637a06db2`,
matching the committed file exactly; it is `root:root` mode 0644. The exact
prior helper, full marker, version, and build date are protected in the
root-owned mode-0700 rollback directory:

```text
/root/vesta-backups/native-web-proxy-authority-a357eb66
```

Remote `bash -n` and source-level valid/invalid authority cases passed,
including an exact `[::1]` Host result. Nginx and Apache syntax passed, all
three Nginx, Apache, and Vesta services remained active, and both host-local
and public checks retained HTTP 301 and HTTPS 200 for
`app.example.com`. The first pre-deployment `nginx -t`, run at the SSH
session's default file-descriptor limit, reproduced the already documented
`Too many open files` failure; rerunning with the host's established
`ulimit -n 65535` passed before and after deployment. The initial deployment
write used a placeholder `2026-08-06T12:00:00Z` build value; it was corrected
under the same release lock to the actual UTC deployment time above. Neither
attempt changed domain/user authentication, workload state, or production.

## Exact restoration and cleanup

The protected archive restored the original domain record, production ACME
account, cron record, certificate material, renders, and `public_html`.
Restoration proved:

- the complete original domain line was exact;
- the original production certificate SHA-256 fingerprint was exact;
- every snapshotted file hash was exact;
- baseline HTTP and HTTPS response bodies were byte-identical;
- public HTTP and HTTPS both returned 200;
- Nginx and Apache configuration tests passed and Nginx, Apache, and Vesta
  remained active;
- the original loopback port 8420 listener remained present.

The echo services, echo files, fixture directory, marker file, ACME/SSL test
duplicates, panel sessions, one-time credentials, browser state, temporary
authentication hash, temporary manifests, failed staging trees, and payloads
were removed. Only the protected rollback/evidence roots documented above were
retained. The final deployed control-plane runtime is `a357eb66`; the
original administrator authentication, domain workload, and domain authority
are restored exactly. No Milestone 3 blocker remains.

## Final local release gate

The complete Task 6 affected-system gate ran from the repository root on
2026-08-06 and passed:

- `bash -n` accepted `bin/v-add-web-domain`,
  `bin/v-change-web-domain-proxy-options`,
  `bin/v-delete-web-domain-proxy`, `bin/v-add-letsencrypt-domain`,
  `bin/v-add-web-domain-ssl`, `bin/v-update-letsencrypt-ssl`,
  `func/vx/proxy.sh`, and `test/test_web_domain_proxy.sh` with exit 0.
- `php -l` reported no syntax errors for `web/inc/vx_proxy_form.php`,
  `web/add/web/index.php`, and `web/edit/web/index.php`.
- `bash test/test_web_domain_proxy.sh` reported
  `Web domain proxy tests passed.`
- `php test/test_web_proxy_form.php` reported
  `Web proxy form tests passed.`
- `bash test/compose/test-routes.sh` reported
  `Compose route tests passed.`
- `bash test/compose/test-ingress-consumers.sh` reported
  `Compose ingress consumer tests passed.`
- `bash test/compose/test-web-ui.sh` reported
  `Compose web UI static tests passed.`
- `bash test/test_compose_docs.sh` reported
  `Compose documentation consistency checks passed.`
- `git diff --check` completed with exit 0 and no output.

The final release diff adds regression coverage, the two approved panel help
messages, the proxy-disable correction, this validation record, and operator
documentation. It adds no upstream catalog, URL/header approval layer,
protected proxy specification, duplicate state store, or panel redesign. No
production mutation was authorized or performed, and the optional production
comparison was not run.

After the final-review correction, the complete Task 6 gate was rerun and
again passed with the exact results above. `git diff --check` also passed for
the code/test commit and the subsequent evidence update.
