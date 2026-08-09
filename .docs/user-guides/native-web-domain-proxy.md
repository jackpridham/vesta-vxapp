# Native Web-Domain Reverse Proxy

Use the native Vesta web-domain proxy when an owned website should forward to
an HTTP(S) application instead of serving its `public_html` directory. The
domain's Vesta `web.conf` record is authoritative, and Vesta renders the HTTP
and HTTPS Nginx virtual hosts from that state.

## Create in the panel

1. Open **Web**, select **Add Web Domain**, and enter the domain and its normal
   web-domain settings.
2. Expand **Advanced Options** and enable **Proxy Support**.
3. Enter the application URL in **Proxy Target URL**, such as
   `http://127.0.0.1:8420`.
4. Select **application** for **Proxy Profile**, enable **Preserve Host
   Header**, and enter `60` for **Proxy Timeout**.
5. In **Proxy Headers**, enter one request header per line as `Name: Value`:

   ```text
   X-Business-GUID: EXAMPLE-GUID
   ```

6. Save the domain. Use the normal Vesta SSL/Let's Encrypt controls when HTTPS
   is required.

When a target is set, Nginx forwards this website to the target instead of
serving its `public_html` directory.

## Edit or disable in the panel

To edit a proxy, open **Web**, edit the domain, expand **Advanced Options**,
and update the existing Proxy Support fields. The saved target, profile,
preserve-Host setting, timeout, and headers are preloaded. Save the domain to
render and activate the changes.

To disable the proxy, edit the domain, clear **Proxy Support**, and save. Vesta
removes the native proxy settings and renders the ordinary web vhost again;
the domain returns to its `public_html` content while its normal SSL and
Let's Encrypt state is retained.

## Command line

Create a web domain with an application proxy:

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

Repeat `--header 'Name: Value'` for additional request headers.

Edit all compact proxy options for an existing domain:

```bash
/usr/local/vesta/bin/v-change-web-domain-proxy-options \
  USER DOMAIN proxy 'http://127.0.0.1:8420' \
  application yes 60 \
  'X-Business-GUID: EXAMPLE-GUID' yes
```

Multiple headers use `||` inside the single `HEADERS` argument:

```text
X-Business-GUID: EXAMPLE-GUID||X-Another-Header: example
```

Inspect the authoritative domain state through the supported list command:

```bash
/usr/local/vesta/bin/v-list-web-domain USER DOMAIN json
```

Disable proxy support and restore the normal web vhost:

```bash
/usr/local/vesta/bin/v-delete-web-domain-proxy USER DOMAIN yes
```

Do not edit `web.conf` or generated Nginx files directly.

## Docker and Compose boundary

A native web-domain proxy may target an application published by Docker on a
loopback port, such as `127.0.0.1:8420`. The web domain does not create or own
that Docker/Compose project, and its native proxy record is not a Compose
route. Project lifecycle and route ownership remain separate.

`customer-one.example` and `customer-two.example` already use this
native model and do not require recreation for this feature release.
