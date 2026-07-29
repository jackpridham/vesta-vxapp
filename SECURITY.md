# Security Policy

## Reporting a Vulnerability

Report security issues privately to `info@myvestacp.com`. Do not include live
credentials, registry tokens, secret values, or production customer data in a
public issue.

## Docker Compose Security Boundary

- Vesta owner/project state and current `compose.yaml` are authoritative.
  Docker inspect output alone never grants ownership.
- Definitions are canonicalized with Docker Compose in a controlled
  environment, then evaluated by deny-first policy before Docker mutation.
- Ordinary users act only on their own `standard` projects. Privileged
  profiles require explicit administrator assignment and expiry.
- Self-service confirmation uses a short-lived, root-owned, non-symlink
  preview bound to source/canonical digests and the expected revision.
- Secrets and registry authentication must not appear in argv, Compose
  environment, metadata, logs, audit, UI responses, or unencrypted backups.
- Privileged mode, Docker sockets, host PID/IPC, devices, arbitrary host
  paths, unsafe capabilities, and unapproved host networking are rejected.
- Cleanup is owner/project-scoped, retains application data by default, and
  never uses global Docker prune.
- HTTP routes remain Vesta-owned and firewall policy is never applied
  automatically.

The detailed controls are in
[the Compose security contract](.docs/contracts/compose-security.md) and
[self-service deployment contract](.docs/contracts/compose-self-service-deployment.md).

## Deployment Boundary

Disposable-staging acceptance is complete. Production promotion is not
authorized by repository state or test evidence; it requires explicit target
authorization, exact file manifests and hashes, rollback backups, and scoped
post-deployment checks.
