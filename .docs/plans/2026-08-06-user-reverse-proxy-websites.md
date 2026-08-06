# Native Web-Domain Reverse Proxy Completion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `$milestone-driven-implementation`. Complete and verify the existing native
> proxy feature. Do not build a second proxy or approval subsystem.

**Goal:** Make the existing web-domain reverse-proxy flow a tested and
documented production feature in both the Vesta panel and command line,
including per-domain custom request headers such as `X-Business-GUID`.

**Architecture:** Keep the implementation already in the repository. Vesta's
owned domain record in `data/users/<user>/web.conf` remains authoritative;
`func/vx/proxy.sh` and the `vx-proxy` Nginx templates render it; the existing
web add/edit pages and Vesta commands create and change it. Setting a target
causes Nginx to forward the website rather than serve `public_html`. Disabling
Proxy Support removes that proxy vhost and returns the domain to its normal
web vhost.

**Tech Stack:** Bash, PHP, Vesta flat-file state, Nginx templates, focused
contract tests, and a disposable staging backend.

---

## Scope decision

The previous plan treated this as a new multi-user security product. That is
not required for the current operator-only use case.

Do not add:

- administrator-approved URLs or per-user upstream grants;
- approved-header lists, business-header allowlists, or header-name policy;
- protected one-use JSON specs or another form-to-command transport;
- another state store alongside the domain's `web.conf` record;
- a new permission model, website-type wizard, or custom header UI component;
- new transaction/lock/rollback machinery for ordinary Vesta web edits;
- a Compose route for these cross-owner tenant ingress domains;
- a new API endpoint in this milestone.

Keep only the existing syntax validation needed to avoid invalid Vesta or
Nginx state: an HTTP(S) target, a supported mode/profile, a bounded numeric
timeout, and renderable `Name: Value` headers. Keep existing Docker/Compose
route-ownership checks unchanged.

## Feasibility and current-state confirmation

This functionality already exists. The remaining work is regression coverage,
small usability clarification, documentation, and a clean end-to-end proof.

| Required capability | Existing implementation |
| --- | --- |
| Create a normal Vesta website with optional reverse proxy | `web/add/web/index.php` and `bin/v-add-web-domain` |
| Enter an arbitrary HTTP(S) target | `v_proxy_target` and `--proxy-target` |
| Set proxy mode/profile, preserve Host, and timeout | Existing add/edit fields and `PROXY_*` state |
| Enter custom request headers | Multiline `v_proxy_headers`; repeated `--header` on create; serialized `HEADERS` on edit |
| Persist the settings per Vesta owner/domain | `data/users/<user>/web.conf` |
| Render the upstream and headers into Nginx | `func/vx/proxy.sh` plus `vx-proxy.tpl`/`.stpl` |
| Edit an existing proxy website | `web/edit/web/index.php` and `bin/v-change-web-domain-proxy-options` |
| Inspect the state from CLI | `bin/v-list-web-domain` and `bin/v-list-web-domains` |
| Return the site to normal hosting | `bin/v-delete-web-domain-proxy` and the Proxy Support checkbox |

The panel already exposes **Proxy Support**, **Proxy Target URL**, **Proxy
Profile**, **Preserve Host Header**, **Proxy Timeout**, and **Proxy Headers**.
`web/inc/vx_proxy_form.php` converts one header per textarea line to the `||`
format stored in `PROXY_HEADERS` and safely constructs the current CLI calls.

The rendered native proxy already provides:

- `proxy_pass` to the configured URL;
- preserved `Host` when selected;
- `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`,
  `X-Forwarded-Host`, and `X-Forwarded-Port`;
- HTTP/1.1 and profile-specific upgrade/streaming behavior;
- a `proxy_set_header` directive for each custom header, including
  `X-Business-GUID`.

The existing SSL/ACME path is also designed to work with `vx-proxy`:

- `vx-proxy.tpl` includes `nginx.%domain%.conf*`, allowing the temporary
  HTTP-01 challenge location written by `v-add-letsencrypt-domain` to take
  precedence over the catch-all proxy location;
- `vx-proxy.stpl` includes the matching `snginx.%domain%.conf*` files and
  references the installed certificate/key;
- `v-add-web-domain-ssl` renders the proxy `.stpl` whenever the domain has a
  proxy template;
- `v-update-letsencrypt-ssl` finds domains with `LETSENCRYPT='yes'` whose
  certificate has fewer than 31 days remaining and renews them through
  `v-add-letsencrypt-domain`.

Those code paths make SSL feasible, but they must be covered explicitly by
the tests and staging lifecycle below. Merely checking that an `.stpl` file
exists is not sufficient release evidence.

The production migration and validation records confirm that
`castlesoncommand.com.au` and `newcastleslushiehire.com.au` already use this
native `vx-proxy` state to reach the loopback-published `slave-vxapp` service,
with a distinct `X-Business-GUID` on each domain. No new routing model or
tenant migration is required.

## Supported operator flows

### Create from CLI

This interface already exists and remains the supported create flow:

```bash
/usr/local/vesta/bin/v-add-web-domain \
  USER DOMAIN IP no none '' \
  --proxy-target 'http://127.0.0.1:8420' \
  --proxy-mode proxy \
  --proxy-profile application \
  --proxy-preserve-host yes \
  --proxy-timeout 60 \
  --header 'X-Business-GUID: EXAMPLE-GUID'
```

Repeat `--header 'Name: Value'` for additional headers.

### Edit from CLI

This interface already exists and remains the supported compact edit flow:

```bash
/usr/local/vesta/bin/v-change-web-domain-proxy-options \
  USER DOMAIN proxy 'http://127.0.0.1:8420' \
  application yes 60 \
  'X-Business-GUID: EXAMPLE-GUID' yes
```

Multiple headers use the same persisted separator in the single `HEADERS`
argument:

```text
X-Business-GUID: EXAMPLE-GUID||X-Another-Header: example
```

This positional form is intentionally retained: it is already used by the
panel/integration code and is compact enough for a future API adapter.

### Inspect and disable from CLI

```bash
/usr/local/vesta/bin/v-list-web-domain USER DOMAIN json
/usr/local/vesta/bin/v-delete-web-domain-proxy USER DOMAIN yes
```

No direct `web.conf` or Nginx editing is part of the supported workflow.

---

## Milestone 1: Add focused regression coverage

### Task 1: Test proxy parsing, validation, and Nginx rendering

**Files:**

- Create: `test/test_web_domain_proxy.sh`
- Test: `func/vx/proxy.sh`
- Test: `func/domain.sh`
- Test: `bin/v-add-letsencrypt-domain`
- Test: `bin/v-add-web-domain-ssl`
- Test: `bin/v-update-letsencrypt-ssl`
- Test: `install/debian/10/templates/web/nginx/vx-proxy.tpl`
- Test: `install/debian/10/templates/web/nginx/vx-proxy.stpl`
- Test: `example-of-linux-root-folder/usr/local/vesta/data/templates/web/nginx/vx-proxy.tpl`
- Test: `example-of-linux-root-folder/usr/local/vesta/data/templates/web/nginx/vx-proxy.stpl`

- [x] Add a small Bash harness that stubs Vesta error handling and sources
  `func/vx/proxy.sh`.
- [x] Assert create-style named options parse target, mode, profile,
  preserve-host, timeout, and one or more `--header` values.
- [x] Assert a loopback HTTP URL, an HTTPS URL, and
  `X-Business-GUID: EXAMPLE-GUID` pass the current validation.
- [x] Assert malformed URLs, modes, profiles, timeouts, and unrenderable
  header syntax fail. Do not add URL or header approval rules.
- [x] Render an application-profile proxy block and assert the target,
  standard forwarded headers, preserved Host, upgrade behavior, timeout, and
  custom headers are present.
- [x] Cover preserve-host `no`, redirect `301`, and temporary redirect `302`.
- [x] Assert installer and synthetic-root `vx-proxy` templates remain in sync
  and contain `%vx_proxy_location_block%`.
- [x] Assert the HTTP template includes `nginx.%domain%.conf*`, the HTTPS
  template includes `snginx.%domain%.conf*`, and a generated HTTP-01 regex
  location is not swallowed by the catch-all `location /` proxy.
- [x] Assert `v-add-web-domain-ssl` renders `PROXY.stpl` for an enabled native
  proxy without clearing `PROXY_TARGET` or `PROXY_HEADERS`.
- [x] Assert the renewal command selects only `LETSENCRYPT='yes'` domains
  inside its renewal window and delegates renewal to
  `v-add-letsencrypt-domain`.

Run:

```bash
bash -n func/vx/proxy.sh test/test_web_domain_proxy.sh
bash test/test_web_domain_proxy.sh
```

### Task 2: Test the panel form and command wiring

**Files:**

- Create: `test/test_web_proxy_form.php`
- Test: `web/inc/vx_proxy_form.php`
- Test: `web/add/web/index.php`
- Test: `web/edit/web/index.php`
- Test: `web/templates/admin/add_web.html`
- Test: `web/templates/admin/edit_web.html`
- Test: `web/templates/user/edit_web.html`

- [x] Cover empty, single-line, multiline, CRLF, blank-line, and surrounding
  whitespace handling for `v_proxy_headers`.
- [x] Assert persisted `Header: Value||Header-Two: Value` converts back into
  one textarea line per header.
- [x] Assert the add helper emits the target, mode, profile, preserve-host,
  timeout, and one shell-escaped `--header` argument per line.
- [x] Assert the edit helper emits the exact positional CLI fields, including
  the serialized custom headers as one escaped argument.
- [x] Add static controller assertions that create calls `v-add-web-domain`,
  edit calls `v-change-web-domain-proxy-options`, disable calls
  `v-delete-web-domain-proxy`, and the existing CSRF/owner scope is unchanged.
- [x] Assert all existing add/edit templates expose the proxy target and
  header fields.

Run:

```bash
php -l web/inc/vx_proxy_form.php
php -l web/add/web/index.php
php -l web/edit/web/index.php
php test/test_web_proxy_form.php
```

### Milestone 1 implementation record

- **Completed behavior and authority boundary:** focused regression coverage now
  exercises native proxy option parsing, syntax validation, Nginx rendering,
  mirrored templates, ACME precedence, SSL rendering, renewal selection, panel
  header normalization, shell escaping, controller wiring, CSRF/owner scope,
  and all existing proxy form surfaces. Vesta web-domain state remains the only
  authority; no URL/header approval layer or additional state store was added.
- **Files and commits:** `func/vx/proxy.sh`,
  `test/test_web_domain_proxy.sh`, and `test/test_web_proxy_form.php` in
  `a3b378ae`, `43ca8fbd`, and `bcb3d3f6`.
- **Focused tests:** Bash syntax, `bash test/test_web_domain_proxy.sh`, PHP lint
  for the helper and add/edit controllers, `php test/test_web_proxy_form.php`,
  and `git diff --check` passed.
- **Specification result:** PASS after focused remediation of URL hostname
  validation and behavioral SSL/renewal evidence.
- **Deferred findings:** none.
- **Next product milestone:** add only the two approved help messages to the
  existing add/edit Proxy Support forms.

## Milestone 2: Make the existing UI self-explanatory

### Task 3: Add two concise help messages

**Files:**

- Modify: `web/templates/admin/add_web.html`
- Modify: `web/templates/admin/edit_web.html`
- Modify: `web/templates/user/edit_web.html`

- [x] Under **Proxy Target URL**, add:

  > When set, Nginx forwards this website to the target instead of serving
  > its public_html directory.

- [x] Under **Proxy Headers**, add:

  > Enter one request header per line as Name: Value.

- [x] Keep the current Advanced Options → Proxy Support layout and all
  existing controls. Do not add a new wizard, approval notice, warning modal,
  or custom JavaScript component.
- [x] Preserve the ordinary-user edit template even though the current
  operational use is administrator-only, so the existing shared panel surface
  does not drift.

Run:

```bash
php -l web/add/web/index.php
php -l web/edit/web/index.php
php test/test_web_proxy_form.php
```

### Milestone 2 implementation record

- **Completed behavior and authority boundary:** the existing administrator
  add/edit and ordinary-user edit forms now explain that a configured target
  replaces `public_html` delivery and that request headers use one
  `Name: Value` line each. The existing Proxy Support layout and controls are
  unchanged.
- **Files and commit:** `web/templates/admin/add_web.html`,
  `web/templates/admin/edit_web.html`, and `web/templates/user/edit_web.html`
  in `5f378a7e`.
- **Focused tests:** PHP lint for the add/edit controllers,
  `php test/test_web_proxy_form.php`, and scoped `git diff --check` passed.
- **Specification result:** PASS.
- **Deferred findings:** none.
- **Next product milestone:** execute the disposable sydlocal create, ACME
  staging issuance/renewal, edit, panel-save, rebuild, HTTPS, disable, and
  cleanup lifecycle without changing production or existing tenant proxies.

## Milestone 3: Prove create, edit, rebuild, and disable

### Task 4: Run a disposable staging lifecycle

**Files:**

- Create: `.docs/validation/2026-08-06-native-web-proxy-release.md`
- Modify: `.docs/README.md`

Use a disposable staging user/domain, public DNS resolving to the staging
host, and a local echo backend that records received paths and headers. Ports
80 and 443 must reach the staging Nginx instance. Use the Let's Encrypt
staging endpoint for issuance and renewal testing. Do not mutate production,
either existing tenant domain, or `slave/slave-vxapp`.

- [x] Create the staging domain through the documented
  `v-add-web-domain` proxy options with an application profile, preserve-host
  `yes`, timeout `60`, and a disposable `X-Business-GUID`.
- [x] Assert `v-list-web-domain ... json`, the staging owner's `web.conf`, and
  both HTTP/SSL Nginx renders agree on target and headers.
- [x] Run `nginx -t`, reload through Vesta, and request the staging hostname.
  Assert the echo backend receives the original Host, expected
  `X-Forwarded-*` headers, path/query, and exact disposable business GUID.
- [x] Run
  `LE_STAGING=yes /usr/local/vesta/bin/v-add-letsencrypt-domain USER DOMAIN`
  and require successful HTTP-01 validation and certificate installation.
  Assert the echo backend received no `/.well-known/acme-challenge/` request;
  the temporary Vesta ACME location must answer that path locally instead of
  forwarding it to the application.
- [x] Assert the domain record has `SSL='yes'` and `LETSENCRYPT='yes'`, the
  certificate/key files exist in Vesta user state and the user's web config,
  the SSL `vx-proxy` vhost references them, and `nginx -t` passes.
- [x] Assert the administrator cron authority contains the normal
  `v-update-letsencrypt-ssl` job installed by successful issuance.
- [x] Verify the issued staging certificate's SAN matches the disposable
  domain. Make a real HTTPS request with SNI to a non-challenge application
  path and assert it reaches the echo backend with the same Host,
  `X-Forwarded-*`, and disposable `X-Business-GUID` values. Because the Let's
  Encrypt staging chain is intentionally not publicly trusted, validate the
  certificate metadata separately and use the staging CA or an explicitly
  insecure curl only for this disposable transport assertion.

  Use checks equivalent to:

  ```bash
  openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null \
    2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
  curl --fail --silent --show-error --insecure \
    --resolve "$DOMAIN:443:$STAGING_IP" "https://$DOMAIN/proxy-e2e?source=ssl"
  ```
- [x] Edit the target or header with
  `v-change-web-domain-proxy-options`; assert state, renders, `nginx -t`, and
  the backend request all contain the new value and not the old one.
- [x] Load the domain in the panel, confirm all proxy fields are populated,
  make one disposable header change, save, and confirm it persists.
- [x] Run the normal web-domain rebuild and confirm the target and header
  survive, `SSL='yes'` and `LETSENCRYPT='yes'` remain set, the SSL vhost still
  references the installed certificate, and HTTPS still reaches the backend.
- [x] On an isolated staging host with no unrelated certificate inside its
  renewal window, install a disposable one-day certificate through
  `v-change-web-domain-sslcert` while leaving the domain's existing
  `LETSENCRYPT='yes'` authority intact. Capture its fingerprint, run
  `LE_STAGING=yes /usr/local/vesta/bin/v-update-letsencrypt-ssl`, and assert
  the scheduled renewal path replaces that fingerprint with a new Let's
  Encrypt staging certificate.

  Generate and install the renewal-due fixture through the public SSL command:

  ```bash
  SSL_FIXTURE_DIR=$(mktemp -d)
  chmod 700 "$SSL_FIXTURE_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout "$SSL_FIXTURE_DIR/$DOMAIN.key" \
    -out "$SSL_FIXTURE_DIR/$DOMAIN.crt"
  /usr/local/vesta/bin/v-change-web-domain-sslcert \
    "$USER" "$DOMAIN" "$SSL_FIXTURE_DIR" yes
  BEFORE_FINGERPRINT=$(openssl x509 -in \
    "/usr/local/vesta/data/users/$USER/ssl/$DOMAIN.crt" \
    -noout -fingerprint -sha256)
  LE_STAGING=yes /usr/local/vesta/bin/v-update-letsencrypt-ssl
  AFTER_FINGERPRINT=$(openssl x509 -in \
    "/usr/local/vesta/data/users/$USER/ssl/$DOMAIN.crt" \
    -noout -fingerprint -sha256)
  test "$BEFORE_FINGERPRINT" != "$AFTER_FINGERPRINT"
  ```

  Remove the exact temporary fixture directory after the assertion.
- [x] After renewal, require `SSL='yes'`, `LETSENCRYPT='yes'`, a valid matching
  SAN, `nginx -t`, and a successful HTTPS application request reaching the
  backend with the custom header. This is the proof that renewal does not
  revert the domain to `public_html` or lose its proxy/header state.
- [x] Disable proxy support with `v-delete-web-domain-proxy`; confirm the
  `PROXY_*` state and proxy vhost are cleared while the normal web vhost serves
  a marker file from `public_html` over both HTTP and HTTPS and the domain's
  Let's Encrypt renewal state remains functional.
- [x] Delete only the disposable domain/backend and record the test evidence.

If separately authorized, finish with a read-only comparison of the two
existing production tenant domain records and renders. Record the target,
profile, header name, and equality result without copying live GUID values.
Also verify each public HTTPS endpoint presents a currently valid trusted
certificate for its hostname and reaches the application. If they already
match native `vx-proxy` state, make no change.

### Milestone 3 implementation record

- **Completed behavior and authority boundary:** the user-authorized dev host
  at `192.168.200.100` received the exact additive control-plane candidate and
  `admin/slave.jackpridham.com` completed a protected real create, CLI edit,
  authenticated panel edit, rebuild, Let's Encrypt staging issuance and
  scheduled renewal, immediate disable-to-`public_html`, HTTPS, and cleanup
  lifecycle. Production, tenant domains, Compose workloads, DNS, firewall, and
  WAN routing were not changed. Existing GUID and administrator authentication
  values never entered repository evidence.
- **Files and commits:** `bin/v-delete-web-domain-proxy` and
  `test/test_web_domain_proxy.sh` in `7beba3ca`; release evidence and index in
  `f4a4b76c`, `d864fd72`, and `3e6064fa`.
- **Focused tests and evidence:** local Bash/PHP proxy suites and affected
  Compose route/ingress/UI/docs gates passed. Live JSON, `web.conf`, HTTP/SSL
  renders, Nginx/Apache, echo-backend forwarding, ACME non-forwarding,
  certificate SAN/fingerprint renewal, public HTTP/HTTPS, and exact restoration
  checks passed. The deployed runtime marker and command hash match
  `7beba3ca`; the original domain, certificate, response bodies, admin shadow
  line, `user.conf`, and port 8420 service were restored exactly.
- **Specification result:** PASS after closing the live-create evidence blocker
  with the documented `v-add-web-domain` long-option command.
- **Deferred findings:** none. The pre-existing missing `PHP-FPM-82` template
  warning affected another derived administrator render and not this domain.
- **Next product milestone:** publish the operator guide, run the complete
  affected-system release gate, perform final specification and code-quality
  review, reconcile the plan/evidence, and commit closeout.

## Milestone 4: Document and release

### Task 5: Add the operator guide

**Files:**

- Create: `.docs/user-guides/native-web-domain-proxy.md`
- Modify: `.docs/README.md`
- Modify: `docs/container-orchestration.md`

- [x] Document panel create/edit/disable using the existing Proxy Support
  fields.
- [x] Document the exact CLI create, edit, list, and disable commands shown in
  this plan.
- [x] Use only `EXAMPLE-GUID` values.
- [x] Explain briefly that native domain proxy state may point at a
  Docker-published loopback port but does not create or own a Docker/Compose
  project or Compose route.
- [x] State that `castlesoncommand.com.au` and
  `newcastleslushiehire.com.au` are already on this model and do not require
  recreation as part of this feature release.

### Task 6: Run final validation and commit

Run:

```bash
bash -n bin/v-add-web-domain \
  bin/v-change-web-domain-proxy-options \
  bin/v-delete-web-domain-proxy \
  bin/v-add-letsencrypt-domain \
  bin/v-add-web-domain-ssl \
  bin/v-update-letsencrypt-ssl \
  func/vx/proxy.sh \
  test/test_web_domain_proxy.sh
php -l web/inc/vx_proxy_form.php
php -l web/add/web/index.php
php -l web/edit/web/index.php
bash test/test_web_domain_proxy.sh
php test/test_web_proxy_form.php
bash test/compose/test-routes.sh
bash test/compose/test-ingress-consumers.sh
bash test/compose/test-web-ui.sh
bash test/test_compose_docs.sh
git diff --check
```

- [x] Confirm no upstream catalog, URL/header approval, protected proxy spec,
  duplicate state store, panel redesign, or production mutation entered the
  diff.
- [x] Record the exact validation results in the release evidence document.
- [x] Commit the tested implementation and documentation while preserving
  unrelated user changes.

### Milestone 4 implementation record

- **Completed behavior and authority boundary:** the operator guide documents
  the existing panel and exact CLI create, edit, list, and disable workflows,
  including `EXAMPLE-GUID` request headers. The architecture guide now makes
  explicit that a native web-domain proxy may consume a Docker-published
  loopback port without creating or owning a Compose project or route. The two
  existing tenant domains require no recreation. No approval/catalog/spec,
  duplicate authority, panel redesign, or production mutation was introduced.
- **Files and commit:** `.docs/user-guides/native-web-domain-proxy.md`,
  `.docs/README.md`, `docs/container-orchestration.md`, this plan, and the
  native proxy release evidence in the Milestone 4 closeout commit.
- **Final tests:** the complete Task 6 Bash/PHP syntax, native proxy,
  Compose-route, ingress-consumer, web-UI, documentation, and whitespace gate
  passed exactly as recorded in the release evidence.
- **Specification result:** PASS by self-review against Tasks 5 and 6 and by
  final independent specification review after the authority-parser
  correction.
- **Deferred findings:** final code-quality review noted that the native
  disable regression harness uses static source assertions; the live dev
  lifecycle proves the behavior, but a future executable stub would make the
  local regression stronger.
- **Next product milestone:** none; all planned product milestones and local
  release gates are complete.

### Final-review correction record

- **Blocker and fix:** final review found that explicit target ports were not
  validated and bracketed IPv6 produced an invalid preserve-host=no Host
  value. Commit `a357eb66` adds a reusable HTTP(S) authority parser and focused
  hostname, IPv4, IPv6, malformed-bracket, empty-port, nonnumeric-port, zero,
  and out-of-range-port coverage without adding an approval policy.
- **Exact gates:** the full Task 6 Bash/PHP syntax, proxy, Compose route,
  ingress-consumer, web-UI, documentation, and whitespace gate passed after
  the correction.
- **Dev deployment:** only committed `func/vx/proxy.sh` was promoted under the
  release lock. Dev now reports marker
  `a357eb6649979130c71752b24cdf79cece98032a`, version
  `0.9.9-0-16+vxapp.a357eb66`, build date `2026-08-06T09:20:46Z`, and helper
  SHA-256
  `1ea77efd1e64bf039b2087f47c02d06c05cc5ba91cb040190ba0886637a06db2`.
  Remote syntax/source cases, Nginx/Apache/service checks, and public
  `slave.jackpridham.com` HTTP 301/HTTPS 200 checks passed. Exact prior runtime
  authority is retained at
  `/root/vesta-backups/native-web-proxy-authority-a357eb66`.
- **Boundary:** no domain, user authentication, workload, or production state
  was mutated. The deferred static delete harness was not changed.
- **Final independent reviews:** specification and code-quality rechecks both
  passed the authority-parser correction with no remaining blocker. The static
  native-disable harness observation remains the only non-blocking deferred
  item.

## Acceptance checklist

- [x] The panel can create and edit a proxy website using a directly entered
  HTTP(S) URL and custom `Name: Value` request headers.
- [x] `X-Business-GUID` is persisted and reaches a disposable upstream.
- [x] CLI create, edit, list, and disable are tested and documented.
- [x] Vesta `web.conf`, list output, HTTP render, and SSL render agree.
- [x] A web-domain rebuild preserves the target and headers.
- [x] HTTP-01 challenge requests are answered by Vesta and do not reach the
  proxy target.
- [x] Let's Encrypt staging issuance enables SSL and the HTTPS domain reaches
  the configured application target with its custom header.
- [x] The actual scheduled renewal command replaces a renewal-due certificate
  while preserving the proxy target, headers, SSL vhost, and HTTPS service.
- [x] Disabling Proxy Support returns the site to `public_html` delivery.
- [x] Existing Compose/Docker route ownership behavior is unchanged.
- [x] No administrator-approved URL/header or other new approval layer exists.
- [x] Existing tenant proxies and `slave/slave-vxapp` are not changed by the
  implementation or staging proof.
