---
name: runtime-layout
description: "Use when you need to map repository paths to live-host paths, understand where generated Vesta configs come from, or change installer and template files including phpMyAdmin and Roundcube webmail paths."
---

# Runtime Layout

Use this skill before editing files when the main question is "where does this live on the host?" or "which source file generates this runtime file?"

## Core Mapping

- Repo root maps to `/usr/local/vesta` on a live host.
- `bin/` maps to `/usr/local/vesta/bin/`.
- `func/` maps to `/usr/local/vesta/func/`.
- `web/` maps to `/usr/local/vesta/web/`.
- `install/` maps to `/usr/local/vesta/install/`.
- `src/` maps to `/usr/local/vesta/src/`.
- `upd/` maps to `/usr/local/vesta/upd/`.
- `test/` maps to `/usr/local/vesta/test/`.
- `example-of-linux-root-folder/` is a synthetic `/` from a live host.
- `example-of-linux-root-folder/usr/local/vesta/...` still represents `/usr/local/vesta/...` on the host.

## Config And Template Lifecycle

- Vesta user state under `/usr/local/vesta/data/users/<user>/` is the source of truth.
- Web-domain records in `web.conf` are rendered into `/home/<user>/conf/web/`.
- Installed web templates on a host live under `/usr/local/vesta/data/templates/web/...`.
- In the repo, shipped installer/default templates live under `install/debian/<version>/templates/web/...`.
- If a change affects how domains are rendered, inspect both the source template and the generated config path it produces.

## When To Check Multiple Locations

- If changing a runtime helper or CLI command, edit the root repo files first.
- If changing default shipped templates or installer payloads, check the relevant `install/debian/<version>/...` trees.
- If changing file paths exposed through hosted domains, inspect both:
  - server includes under `install/debian/<version>/nginx/`, `install/debian/<version>/pma/`, `install/debian/<version>/roundcube/`
  - Vesta nginx templates under `install/debian/<version>/templates/web/nginx/`

## Special Path Work

Read [references/path-mapping.md](references/path-mapping.md) when:

- you need the full repo-to-host path map
- you are tracing how `/webmail/` works
- you are tracing how `/phpmyadmin/` works
- you are unsure whether a file belongs under the repo root or `example-of-linux-root-folder/`
