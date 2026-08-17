# Host and User Migration Implementation Plan

> **For agentic workers:** Inline execution is selected because the user requested implementation in the current session and the work is one integrated security-sensitive milestone. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Vesta-owned `v-migrate-host` and `v-migrate-user` commands that securely push a host configuration/admin account or one complete user account to another machine over operator-authenticated SSH.

**Architecture:** Thin public commands source focused helpers from `func/vx/migration/`. A shared transport helper opens one OpenSSH control connection so password, agent, or key authentication remains inside OpenSSH; archives are staged in root-only temporary directories and verified by SHA-256 before a transferred receiver applies them. Host migration installs prerequisites on a clean, same-Debian-major target, overlays the exact source Vesta tree and an allowlisted host configuration bundle, then restores only `admin`; user migration requires an already-provisioned target and delegates account fidelity to native `v-backup-user`/`v-restore-user` including Compose state.

**Tech Stack:** Bash, OpenSSH/scp, tar, sha256sum, dpkg/apt, native Vesta backup/restore and rebuild commands.

---

### Task 1: Lock the command and archive contracts

**Files:**
- Create: `.docs/contracts/host-user-migration.md`
- Modify: `.docs/README.md`
- Test: `test/migration/test-host-user-migration.sh`

- [ ] Define source-push operation, root-only authorization, target compatibility, archive schemas, exclusion lists, collision handling, no-cutover behavior, and SSH credential handling.
- [ ] Add failing static tests for both public commands, helper ownership, forbidden ecosystem strings, required archive validation, and OpenSSH control-session use.

### Task 2: Implement shared transport and archive safety

**Files:**
- Create: `func/vx/migration/main.sh`
- Create: `func/vx/migration/transport.sh`
- Create: `func/vx/migration/archive.sh`
- Test: `test/migration/test-host-user-migration.sh`

- [ ] Implement strict target/port/identity validation and interactive endpoint prompts.
- [ ] Open a root SSH control connection with `StrictHostKeyChecking=accept-new`; never read or store an SSH password.
- [ ] Create mode-0700 local/remote staging roots, checksum descriptors, safe archive-member checks, bounded archive sizing, and cleanup traps.
- [ ] Test command construction with fixture SSH/scp binaries and reject traversal, links, special files, invalid endpoints, and forbidden paths.

### Task 3: Implement the remote receiver

**Files:**
- Create: `func/vx/migration/receive.sh`
- Test: `test/migration/test-host-user-migration.sh`

- [ ] Verify root execution, schema/mode, checksum, archive members, source/target OS compatibility, and clean-target requirements before mutation.
- [ ] For user mode, require Vesta already installed, reject `admin`, reject existing users/domain conflicts through native restore, apply `v-restore-user`, rebuild, normalize, and refresh counters.
- [ ] For host mode, install the transferred source installer on a clean target with source-derived service flags, install transferred package names available from apt, overlay the exact transferred Vesta application tree, restore allowlisted configs, restore only `admin`, rebuild, and validate core services.

### Task 4: Implement public adapters

**Files:**
- Create: `bin/v-migrate-host`
- Create: `bin/v-migrate-user`
- Test: `test/migration/test-host-user-migration.sh`

- [ ] Add Vesta headers and stable positional interfaces: `v-migrate-host [TARGET] [PORT] [IDENTITY] [FORCE]` and `v-migrate-user USER [TARGET] [PORT] [IDENTITY] [NORMALIZE]`.
- [ ] Require local root, validate explicit users, prompt for missing SSH connection fields and final confirmation, then invoke shared orchestration.
- [ ] Ensure host mode backs up only `admin`; ensure user mode cannot migrate `admin` and does not modify host configuration.

### Task 5: Validate and document

**Files:**
- Create: `.docs/user-guides/host-user-migration.md`
- Modify: `.docs/README.md`
- Test: `test/migration/test-host-user-migration.sh`

- [ ] Document prerequisites, examples, authentication behavior, clean-target rule, source-retention/no-DNS-cutover boundary, package limitations, and recovery steps.
- [ ] Run `bash -n` on every new Bash file, the focused fixture test, `git diff --check`, and a forbidden-reference scan.
- [ ] Review the final diff for secret exposure, unsafe extraction, destructive defaults, path quoting, and compatibility with native Vesta backup/restore.
- [ ] Commit the complete migration surface.
