# vesta-vxapp

This fork is the source tree for the Vortex `vesta-vxapp` build of myVesta.
The repository maps to `/usr/local/vesta` on a host and includes a secure,
single-host Docker Compose orchestrator for tenant workloads.

Compose owns workload desired state. Vesta owns tenant authorization, package
quotas, deny-first policy, stable project storage, nginx routes, backup and
restore, monitoring, alerts, audit history, and the web panel.

The Docker Compose orchestration implementation is production ready and live
on SydVortex. The control plane was promoted on 2026-07-29, the package
validation prerequisite followed on 2026-07-30, and the exact-image
`slave-vxapp` workload cut over on 2026-07-31 as Vesta owner `slave`, project
`slave-vxapp`, revision 4. The old external project and volumes remain
preserved for no-build rollback during the documented soak and retention
period.

A 2026-07-31 read-only product audit confirmed the production container was
healthy and identified product/operations gaps. The successor release now
implements and validates the software corrections: accurate endpoints/health/quotas,
redacted native-ingress consumers and secret metadata, managed backup policy,
human-readable operator controls, drift/reconcile, roles/notifications, and
trusted image delivery. The separately authorized successor promotion applied
the protected `vxslave-compose` quota package; backup-policy changes still
require external off-host inputs and new authorization.
The canonical audit and correction status are under
`kb-vxapp/@Reports/@Servers/syd.vortexenterprises.com.au/`
`vesta-compose-orchestration-product-audit/`.

The successor runtime candidate is
`8dc0dc9c0317d833d5aa57656ab0a180758a8df0` on
`release/vesta-compose-product-corrections-20260801`. It replaces byte-wise
image-evidence comparison with strict versioned semantic identity, accepts
only the exact production five-field legacy shape, restores a stopped healthy
runtime after successful or failed user backup, and stores generated
ownership-labelled preview definitions while retaining submitted source
separately. The complete gate and sydlocal rehearsal are green, including
23 passed/7 skipped browser tests, exact no-build rollback, mount-guard
rollback/reinstall, and a 600-second post-backup soak. The successor is now
the immutable production authority after a separately authorized 2026-08-02
control-plane promotion. Production now runs the exact 250-path candidate;
managed `slave/slave-vxapp` remains revision 4, healthy, and restart-free with
its five-field evidence unchanged. The stopped external rollback authority is
preserved, the mount guard is active, and `vxslave-compose` reports 109 MB used
of 1024 MB. No production backup or workload mutation occurred.

## Docker Compose Orchestrator

The implemented orchestrator provides:

- stable project identity as `vx-<user>-<project>`;
- protected control state under
  `/usr/local/vesta/data/users/<user>/docker-projects/<project>/`;
- durable bind data under `/home/<user>/docker/<project>/`;
- canonicalization through `docker compose config --format json`;
- constrained create, validate, deploy, inspect/list, start, stop, restart,
  recreate, update, rollback, backup, restore, adopt, migrate, and remove
  commands;
- vx-scoped helpers under `func/vx/compose/`;
- simple container compatibility through Compose-backed adapters;
- owner-only `standard` Compose create/update in the panel through a
  non-mutating impact preview and immutable digest- and revision-bound
  confirmation;
- owner-only interactive `v-docker` access through derived
  `vesta-compose-users` membership and the exact
  `v-run-user-docker-command` broker, with package `DOCKER_PROJECTS`
  entitlement, automatic reconciliation, live authorization checks, and
  bounded stdin;
- administrator-only `admin-approved` profile workflows;
- owner-scoped registry credentials, image pulls, checksum-verified local
  archives, immutable registry/platform identity evidence, protected
  SBOM/provenance attachments, isolated trust adapters, and non-mutating
  update candidates;
- root-owned mode-0600 managed secrets with redacted CLI, JSON, audit, web, and
  log surfaces;
- bridge networking by default, Vesta-owned HTTP routes through `vx-proxy`, and
  expiring administrator profiles for public or host-network workloads;
- project health, logs, metrics, alerts, acknowledgement, notification fan-out,
  audit events, delegated project roles, desired/runtime drift and explicit
  reconcile, typed operations, and user counter reconciliation;
- verified project backup/restore for definitions, binds, named volumes,
  route metadata, audit history, image identity manifests, and encrypted
  secret payloads where `age` is configured, plus scheduled policy,
  retention, replication-adapter state, restore-test state, and freshness
  alerts;
- dry-run-first adoption and legacy `docker.conf` migration.

The implementation deliberately does not provide Kubernetes, Swarm, multi-node
scheduling, host firewall mutation, Docker socket mounts, privileged workloads,
arbitrary host-path mounting, host PID/IPC, devices, global Docker prune, or
production deployment automation.

The self-service milestone reports route impact warnings but does not provide
route mutation UI or managed-secret create/rotate UI. Separate follow-on work
covers managed-secret UI, transactional HTTP-route CRUD, a curated application
catalog, Git/OCI desired-state synchronization, scheduled image updates and
production promotion, and multi-host placement and scheduling.

## Public Commands

Primary project commands:

```text
v-add-docker-project USER PROJECT COMPOSE_FILE [PROFILE]
v-validate-docker-project USER PROJECT [json]
v-deploy-docker-project USER PROJECT
v-list-docker-projects USER [FORMAT]
v-list-docker-project USER PROJECT [FORMAT]
v-start-docker-project USER PROJECT
v-stop-docker-project USER PROJECT
v-restart-docker-project USER PROJECT
v-recreate-docker-project USER PROJECT [SERVICE]
v-change-docker-project USER PROJECT COMPOSE_FILE
v-rollback-docker-project USER PROJECT [REVISION]
v-delete-docker-project USER PROJECT [keep-data]
```

Supporting commands cover project health, logs, stats, alerts, audit, routes,
images, registries, secrets, backup, restore, adoption, migration, web-source
bridges. The full command contract is in
[`.docs/contracts/compose-interfaces.md`](.docs/contracts/compose-interfaces.md).

## Documentation Map

Start here for current Compose work:

- [Documentation index and status](.docs/README.md)
- [Operator architecture and migration guide](docs/container-orchestration.md)
- [Compose project user guide](.docs/user-guides/docker-compose-projects.md)
- [Successor production promotion](.docs/validation/2026-08-02-compose-image-evidence-backup-recovery-production-promotion.md)
- [Security contract](.docs/contracts/compose-security.md)
- [Policy and quota contract](.docs/contracts/compose-policy.md)
- [Storage contract](.docs/contracts/compose-storage.md)
- [Lifecycle and rollback contract](.docs/contracts/compose-lifecycle.md)
- [Networking and route contract](.docs/contracts/compose-networking.md)
- [Images and registry contract](.docs/contracts/compose-images.md)
- [Secrets contract](.docs/contracts/compose-secrets.md)
- [Backup and restore contract](.docs/contracts/compose-backup-restore.md)
- [CLI and web interface contract](.docs/contracts/compose-interfaces.md)
- [Self-service deployment contract](.docs/contracts/compose-self-service-deployment.md)
- [Tenant shell-access contract](.docs/contracts/compose-shell-access.md)

Legacy direct-container documents remain in `.docs/contracts/docker-*` and
`.docs/user-guides/docker-containers.md` for audit history only. They are
superseded by the Compose documents above.

## Implementation Evidence

The Compose implementation range begins at `444f8b67`. The final
production-readiness runtime tree is `3094821d`, with validation evidence
recorded at `7d40704b`. Every checkpoint has matching local/staging evidence,
cleanup notes, and rollback guidance in the authoritative status and
validation documents.

The final closeout passed all 48 Compose shell suites, warning-level ShellCheck
for 32 helpers and 72 adapters, all 23 positive/malicious fixture boundaries,
PHP and JavaScript gates, Playwright discovery for 27 tests, and focused
authenticated self-service acceptance (6/6). A final 39-file live-runtime
comparison on disposable staging proved exact repository bytes, modes, and
`root:root` ownership. Real create/deploy, lifecycle, backup, immutable
preview/update, stale-preview rejection, failed-update recovery, restore, and
scoped deletion all passed.

For the later tenant shell-access change, the exact commit/archive were
verified locally, but deployment was not applied because local
release-readiness prerequisites were incomplete. Development-host acceptance
was not recorded, and no production access occurred during that validation.

The legacy myVesta upstream README follows.

---

<h1 align="center"><a href="https://myvestacp.com">myVesta</a></h1>

<div style="text-align:center">

[![Screenshot of myVesta](https://www.myvestacp.com/screenshot1.png)](https://www.myvestacp.com/)

</div>

<h1 align="center">About</h1>

<p align="center">myVesta is a security and stability-focused fork of VestaCP, exclusively supporting Debian in order to maintain a streamlined ecosystem. Boasting a clean, clutter-free interface and the latest innovative technologies, our project is committed to staying synchronized with official VestaCP commits. We work independently to enhance security and develop new features, driven by our passion for contributing to the open-source community rather than monetary gain. As such, we will offer all features built for myVesta to the official VestaCP project through pull requests, without interfering with their development milestones.</p>

<p align="center"><b><a href="https://github.com/myvesta/vesta/blob/master/Changelog.md">View Changelog</a>
</b></p>

<h1>Links</h1>
<ul>
  <li><a href="https://www.myvestacp.com/">Visit our homepage.</a></li>
  <li><a href="https://forum.myvestacp.com/">Check out our forum for discussions and support.</a></li>
  <li><a href="https://wiki.myvestacp.com/">For more information, take a look at our knowledge base.</a></li>
</ul>

<h1>Features of myVesta</h1>
<ul>
    <li>Support for Debian 11 and 12 (Debian 12 is recommended, but previous Debian releases are also supported)</li>
    <li>Support for MySQL 8</li>
    <li><a href="https://forum.myvestacp.com/viewtopic.php?f=20&t=51">nginx templates</a> that can prevent denial-of-service on your server</li>
    <li><a href="https://forum.myvestacp.com/viewtopic.php?f=18&t=52">Support for multi-PHP versions</a></li>
    <li>You can <a href="https://forum.myvestacp.com/viewtopic.php?f=20&t=350">host NodeJS apps</a></li>
    <li>You can limit the maximum number of sent emails (per hour) <a href="https://github.com/myvesta/vesta/blob/master/install/debian/10/exim/exim4.conf.template#L112-L113">per mail account</a> and <a href="https://github.com/myvesta/vesta/blob/master/install/debian/10/exim/exim4.conf.template#L72-L73">per hosting account</a>, preventing hijacking of email accounts and preventing PHP malware scripts to send spam.</li>
    <li>
      You can completely "lock" myVesta so it can be accessed only via secret URL, for example https://serverhost:8083/?MY-SECRET-URL
      <ul>
        <li>During installation you will be asked to choose a secret URL for your hosting panel</li>
        <li>Literally no PHP scripts will be alive on your hosting panel (won't be able to get executed), unless you access the hosting panel with secret URL parameter. Thus, when it happens that, let's say, some zero-day exploit pops up - attackers won't be able to access it without knowing your secret URL - PHP scripts from VestaCP will be simply dead - no one will be able to interact with your panel unless they have the secret URL.</li>
        <li>You can see for yourself how this mechanism was built by looking at:</li>
        <ul>
          <li><a href="https://github.com/myvesta/vesta/blob/master/src/deb/for-download/php/php.ini#L496">src/deb/for-download/php/php.ini</a></li>
          <li><a href="https://github.com/myvesta/vesta/blob/master/web/inc/secure_login.php">web/inc/secure_login.php</a></li>
        </ul>
        <li>If you didn't set the secret URL during installation, you can do it anytime. Just execute in shell: <code>echo "&lt;?php \$login_url='MY-SECRET-URL';" > /usr/local/vesta/web/inc/login_url.php</code></li>
      </ul>
    </li>
  <li>We <a href="https://github.com/myvesta/vesta/blob/master/install/debian/10/php/php7.3-dedi.patch#L9">disabled dangerous PHP functions</a> in php.ini, so even if, for example, your customer's CMS gets compromised, hacker will not be able to execute shell scripts from within PHP.</li>
  <li>Apache is fully switched to mpm_event mode, while PHP is running in PHP-FPM mode, which is the most stable PHP-stack solution
    <ul><li>OPCache is turned on by default</li></ul>
    <li>Auto-generating LetsEncrypt SSL for server hostname (signed SSL for Vesta 8083 port, for dovecot (IMAP & POP3) and for Exim (SMTP))</li>
    <li>You can change Vesta port during installation or later using one command line: v-change-vesta-port [number]</li>
    <li>ClamAV is configured to block zip/rar/7z archives that contains executable files (just like GMail)</li>
    <li>Backup will run with lowest priority (to avoid load on server), and can be configured to run only by night (and to stop on the morning and continue next night) </li>
    <ul>
    <li>You can compile Vesta binaries by yourself - <a href="https://github.com/myvesta/vesta/blob/master/src/deb/vesta_compile.sh">src/deb/vesta_compile.sh</a></li>
<li>You can even create your own APT repository in a minute</li>
<li>We are using latest nginx version for vesta-nginx package</li>
<li>With your own APT infrastructure you can take security of Vesta-installer infrastructure in your own hands. You will have full control of your Vesta code (this way you can rest assured that there's 0% chance that you'll install malicious packages from repositories that may get hacked)</li>
<li>Binaries that you compile are 100% compatible with official VestaCP from vestacp.com, so you can run official VestaCP code with your own binaries (in case you don't want the source code from this fork)</li>
</ul>
    
  </li>
  </ul>
  
<h1>How to install</h1>
Download the installation script:

```shell
curl -O http://c.myvestacp.com/vst-install-debian.sh
```

Then run it:

```shell
bash vst-install-debian.sh
```

Or use our <a href="https://www.myvestacp.com/install_generator.html">installer generator</a>.

<h1>Useful scripts</h1>
<ul>
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=24&t=50">How to move accounts from one (my)Vesta server to another myVesta server</a></li>
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=17&t=386">WordPress installer in one second </a></li>(v-install-wordpress)
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=17&t=385">Cloning script that will copy the whole site from one (sub)domain to another (sub)domain </a></li>(v-clone-website)
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=17&t=382">Script that will migrate your site from http to https, replacing http to https URLs in database </a></li>(v-migrate-site-to-https)
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=24&t=63">Script for importing cPanel backups to Vesta (thanks to Maks Usmanov - Skamasle) </a></li> (v-import-cpanel-backup)
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=18&t=52">Script that will install multiple PHP versions on your server</a></li>
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=20&t=350">How to host NodeJS apps</a></li>
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=20&t=51">Script that will install nginx templates that can prevent denial-of-service on your server</a></li>
  <li><a href="https://forum.myvestacp.com/viewtopic.php?f=15&t=47">Official VestaCP Softaculous installer</a></li>
</ul>


<h1>Licence</h1>
myVesta is licensed under <a href="https://github.com/serghey-rodin/vesta/blob/master/LICENSE">GPL v3</a> license.
