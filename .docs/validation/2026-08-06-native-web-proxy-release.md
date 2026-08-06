# Native Web-Domain Proxy Dev-Host Validation

- **Validation date:** 2026-08-06
- **Authorized host:** `debian@192.168.200.100` (`dev.jackpridham.com`)
- **Authorized domain:** `admin/slave.jackpridham.com`
- **Initial candidate:** `3fdd617d12ebe903a7480d405e17a1a262717abc`
- **Validated successor:** `7beba3ca6cf0d7dc72c02f3aafb4740e28ebfd6f`
- **Runtime version:** `0.9.9-0-16+vxapp.7beba3ca`
- **Runtime build date:** `2026-08-06T08:28:06Z`
- **Outcome:** all CLI, state, render, HTTP, ACME staging, HTTPS,
  renewal, rebuild, disable, restoration, and cleanup gates passed. The
  authenticated panel preload/save gate remains blocked because the existing
  protected local credentials are not valid on this dev host.

## Authorization and boundaries

The user replaced the original sydlocal staging target with the dev server and
explicitly authorized deployment and testing against `slave.jackpridham.com`.
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

- **Create-equivalent:** Because the authorized domain already existed, the
  create-equivalent path disabled then enabled native proxy support through
  `v-change-web-domain-proxy-options`. List JSON, `web.conf`, HTTP and SSL
  renders agreed on target/profile/timeout/header, `nginx -t` passed, and the
  HTTP request preserved path/query, Host, all expected `X-Forwarded-*`
  fields, and the disposable GUID. A first command attempt lacked exported
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
- **Authenticated panel:** Playwright used the existing mode-0600 local
  environment file against `https://192.168.200.100:8083`. Login timed out
  before the edit page loaded because those credentials are not valid on this
  server. No form was loaded or saved, and administrator authentication was
  not reset or changed. This is the sole unresolved milestone blocker.
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

The echo service, echo files, fixture directory, marker file, ACME/SSL test
duplicates, temporary manifests, failed staging trees, and payloads were
removed. Only the two protected rollback/evidence roots above were retained.
The final deployed control-plane runtime remains `7beba3ca`; the original
domain workload and authority are restored exactly.

## Remaining blocker

Milestone 3 is not fully closed until an authorized valid dev-panel
administrator credential can complete authenticated preload/change/save and
the domain is again restored exactly afterward. Do not reset the administrator
password merely to close this evidence gap.
