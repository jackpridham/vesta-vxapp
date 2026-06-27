# Path Mapping

## Basic Map

- `example-of-linux-root-folder/` -> `/`
- `example-of-linux-root-folder/backup/` -> `/backup/`
- `example-of-linux-root-folder/etc/` -> `/etc/`
- `example-of-linux-root-folder/home/` -> `/home/`
- `example-of-linux-root-folder/root/` -> `/root/`
- `example-of-linux-root-folder/tmp/` -> `/tmp/`
- `example-of-linux-root-folder/var/` -> `/var/`
- `example-of-linux-root-folder/usr/` -> `/usr/`
- `example-of-linux-root-folder/usr/local/vesta/data/` -> `/usr/local/vesta/data/`
- `example-of-linux-root-folder/usr/local/vesta/conf/` -> `/usr/local/vesta/conf/`
- `example-of-linux-root-folder/usr/local/vesta/ssl/` -> `/usr/local/vesta/ssl/`
- `example-of-linux-root-folder/usr/local/vesta/log/` -> `/usr/local/vesta/log/`
- `bin/` -> `/usr/local/vesta/bin/`
- `func/` -> `/usr/local/vesta/func/`
- `install/` -> `/usr/local/vesta/install/`
- `src/` -> `/usr/local/vesta/src/`
- `web/` -> `/usr/local/vesta/web/`
- `upd/` -> `/usr/local/vesta/upd/`
- `test/` -> `/usr/local/vesta/test/`

## Template Placement

- Apache templates on a host live in `/usr/local/vesta/data/templates/web/apache2/`.
- Nginx templates on a host live in `/usr/local/vesta/data/templates/web/nginx/`.
- Generated per-domain Apache and nginx configs live in `/home/<user>/conf/web/`.

## phpMyAdmin And Roundcube Paths

If the task touches `/webmail/` or `/phpmyadmin/`, inspect both the global server include files and the Vesta domain templates that expose those locations.

### `/webmail/`

Primary files:

- `/etc/roundcube/apache.conf`
- `/etc/nginx/conf.d/webmail.inc`
- `/usr/local/vesta/data/templates/web/nginx/force-https-webmail-phpmyadmin.stpl`
- `/usr/local/vesta/data/templates/web/nginx/hosting-webmail-phpmyadmin.stpl`
- `/usr/local/vesta/data/templates/web/nginx/hosting-webmail-phpmyadmin.tpl`

Repo locations usually involved:

- `install/debian/<version>/roundcube/apache.conf`
- `install/debian/<version>/nginx/webmail.inc`
- `install/debian/<version>/templates/web/nginx/force-https-webmail-phpmyadmin.stpl`
- `install/debian/<version>/templates/web/nginx/hosting-webmail-phpmyadmin.stpl`
- `install/debian/<version>/templates/web/nginx/hosting-webmail-phpmyadmin.tpl`

### `/phpmyadmin/`

Primary files:

- `/etc/phpmyadmin/apache.conf`
- `/etc/nginx/conf.d/phpmyadmin.inc`
- `/usr/local/vesta/data/templates/web/nginx/force-https-webmail-phpmyadmin.stpl`
- `/usr/local/vesta/data/templates/web/nginx/hosting-webmail-phpmyadmin.stpl`
- `/usr/local/vesta/data/templates/web/nginx/hosting-webmail-phpmyadmin.tpl`

Repo locations usually involved:

- `install/debian/<version>/pma/apache.conf`
- `install/debian/<version>/nginx/phpmyadmin.inc`
- `install/debian/<version>/templates/web/nginx/force-https-webmail-phpmyadmin.stpl`
- `install/debian/<version>/templates/web/nginx/hosting-webmail-phpmyadmin.stpl`
- `install/debian/<version>/templates/web/nginx/hosting-webmail-phpmyadmin.tpl`
