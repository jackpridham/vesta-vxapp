## Source Metadata
- Source path: `.docs/plans/2026-06-27-docker-panel-management.md`
- Redactions applied: no
- Sensitive categories: none

## Section Inventory
1. Task 3: Extend User, Package, Counter, And Stats Persistence

## Sanitized Section Summaries
### Task 3: Extend User, Package, Counter, And Stats Persistence
- Requires Docker container package quota keys and per-user usage counters to be added to package data, user records, installer payloads, and synthetic runtime fixtures.
- Requires package-change and package-list flows to understand the Docker quota key and reject package downgrades that would undercut current Docker usage unless `FORCE=yes` is used.
- Requires Docker counters to appear in user/package list output and monthly stats, with usage counted from `data/users/<user>/docker.conf`.
- Requires the admin package and user quota pages to expose the Docker container limit using `$_POST['v_docker_containers']`.
- Requires Bash syntax validation for the touched CLI files and PHP linting for the touched package controllers.

## Technical Claims
- `DOCKER_CONTAINERS` is the package-level quota key and `U_DOCKER_CONTAINERS` is the per-user usage key.
- User Docker usage is counted from `data/users/<user>/docker.conf`.
- Docker traffic accounting stays on the existing proxied web-domain bandwidth path; no separate Docker bandwidth collector is introduced in this phase.
- The admin package forms post Docker limits through `$_POST['v_docker_containers']`.

## Sensitive Content Handling
- No sensitive literals detected.
