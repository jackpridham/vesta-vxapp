# Migrating Vesta Hosts and Users

Run migration commands as root on the source Vesta host. The target must be a
reachable Debian host with the same major Debian version. SSH login as root
must be permitted for the migration window.

## SSH authentication

You can omit all connection arguments and answer the prompts:

```bash
/usr/local/vesta/bin/v-migrate-host
```

For password authentication, leave the private-key prompt empty. OpenSSH asks
for the password directly; Vesta does not read or retain it. For key
authentication, provide an absolute private-key path:

```bash
/usr/local/vesta/bin/v-migrate-host debian@new-host.example 22 /root/.ssh/migration
```

The first connection may ask you to confirm the target host key. Verify its
fingerprint through a separate trusted channel before accepting it.

## Migrating host configuration

```bash
/usr/local/vesta/bin/v-migrate-host debian@new-host.example 22 - no
```

On a clean target, the transferred installer provisions the matching Vesta
service stack and then installs the exact Vesta application tree from the
source. Only the `admin` Vesta account is restored. Other users and their
sites are not included.

If Vesta is already installed, inspect the target first and pass `yes` as the
final argument. The command still refuses a target containing any non-admin
Vesta user:

```bash
/usr/local/vesta/bin/v-migrate-host debian@new-host.example 22 - yes
```

The source is retained. Host migration does not copy source IP/firewall,
network, SSH, filesystem-mount, registry credential, TLS-key, or DNS-cutover
state. Packages unavailable in the target Debian repositories are reported
and skipped.

## Migrating one user

Provision the target Vesta host first, then run:

```bash
/usr/local/vesta/bin/v-migrate-user customer debian@new-host.example 22 - yes
```

The last argument controls DNS normalization. Use `yes` when moving the user
to the target's IP and nameservers; use `no` when preserving the source DNS
records for a separately managed cutover.

The command restores the native Vesta account backup, including sites,
databases, files, mail, cron jobs, user directories, and Vesta-managed Docker
state. It refuses `admin`; use `v-migrate-host` for that account. It also
refuses an existing target user, and native Vesta restore rejects domains
already owned by another target account.

## After migration

Before changing DNS, verify the target independently:

```bash
/usr/local/vesta/bin/v-list-users
/usr/local/vesta/bin/v-list-web-domains USER
/usr/local/vesta/bin/v-list-databases USER
/usr/local/vesta/bin/v-list-mail-domains USER
/usr/local/vesta/bin/v-list-docker-projects USER json
```

Check Nginx, Apache/PHP-FPM, database, mail, DNS, and Docker services relevant
to the migrated account. DNS delegation and source retirement are separate,
explicit operator actions.
