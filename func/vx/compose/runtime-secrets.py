#!/usr/bin/env python3
"""Atomically materialize container-readable copies of managed secrets."""

import json
import os
import re
import secrets
import stat
import sys
import time

NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
CLEANUP = None
UNCHANGED = 20


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def binding(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid)


def write_all(fd, value):
    offset = 0
    while offset < len(value):
        count = os.write(fd, value[offset:])
        if count < 1:
            raise ValueError("runtime secret write failed")
        offset += count


def remove_directory(parent_fd, name):
    directory_fd = os.open(
        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    state = os.fstat(directory_fd)
    if not stat.S_ISDIR(state.st_mode) or (state.st_mode & 0o777) != 0o700 \
            or state.st_uid != os.geteuid() or state.st_gid != os.getegid():
        raise ValueError("runtime secret directory authority is invalid")
    for entry in os.listdir(directory_fd):
        entry_state = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
        if not stat.S_ISREG(entry_state.st_mode) or stat.S_ISLNK(entry_state.st_mode):
            raise ValueError("runtime secret member authority is invalid")
        os.unlink(entry, dir_fd=directory_fd)
    os.close(directory_fd)
    os.rmdir(name, dir_fd=parent_fd)


def generation_matches(parent_fd, temporary_fd, names, uid, gid):
    if not names:
        try:
            os.stat("current", dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return True
    try:
        current_fd = os.open(
            "current", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd)
    except FileNotFoundError:
        return False
    try:
        current_state = os.fstat(current_fd)
        if (current_state.st_mode & 0o777) != 0o700 \
                or current_state.st_uid != uid or current_state.st_gid != gid \
                or sorted(os.listdir(current_fd)) != names:
            return False
        for name in names:
            current_secret = os.open(
                name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current_fd)
            candidate_secret = os.open(
                name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=temporary_fd)
            try:
                current_state = os.fstat(current_secret)
                candidate_state = os.fstat(candidate_secret)
                if not stat.S_ISREG(current_state.st_mode) \
                        or (current_state.st_mode & 0o777) != 0o444 \
                        or current_state.st_uid != uid or current_state.st_gid != gid \
                        or current_state.st_size != candidate_state.st_size:
                    return False
                while True:
                    current_chunk = os.read(current_secret, 65536)
                    candidate_chunk = os.read(candidate_secret, 65536)
                    if current_chunk != candidate_chunk:
                        return False
                    if not current_chunk:
                        break
            finally:
                os.close(candidate_secret)
                os.close(current_secret)
        return True
    finally:
        os.close(current_fd)


def clear_runtime(project_root):
    project_fd = os.open(project_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    runtime_fd = os.open("runtime", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                         dir_fd=project_fd)
    try:
        parent_fd = os.open(
            "workload-secrets", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=runtime_fd)
    except FileNotFoundError:
        os.close(runtime_fd)
        os.close(project_fd)
        return
    state = os.fstat(parent_fd)
    if not stat.S_ISDIR(state.st_mode) or (state.st_mode & 0o777) != 0o700 \
            or state.st_uid != os.geteuid() or state.st_gid != os.getegid():
        raise ValueError("runtime secret parent authority is invalid")
    if os.geteuid() != 0 \
            and os.environ.get("VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL") == "clear-fsync":
        raise OSError("injected runtime secret clear fsync failure")
    entries = os.listdir(parent_fd)
    for entry in entries:
        if entry not in ("current", "previous") and not entry.startswith(".next."):
            raise ValueError("runtime secret parent contains an unknown member")
        entry_state = os.stat(entry, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(entry_state.st_mode) or stat.S_ISLNK(entry_state.st_mode):
            raise ValueError("runtime secret generation authority is invalid")
    for entry in entries:
        remove_directory(parent_fd, entry)
    os.close(parent_fd)
    os.rmdir("workload-secrets", dir_fd=runtime_fd)
    os.fsync(runtime_fd)
    os.close(runtime_fd)
    os.close(project_fd)


def main():
    global CLEANUP
    if sys.argv[1] == "clear":
        clear_runtime(sys.argv[2])
        return
    project_root, workload_path = sys.argv[1:3]
    authority_uid, authority_gid = os.geteuid(), os.getegid()
    workload_fd = os.open(workload_path, os.O_RDONLY | os.O_NOFOLLOW)
    workload_state = os.fstat(workload_fd)
    if not stat.S_ISREG(workload_state.st_mode) \
            or (workload_state.st_mode & 0o777) != 0o600 \
            or workload_state.st_uid != authority_uid \
            or workload_state.st_gid != authority_gid:
        raise ValueError("workload authority is invalid")
    with os.fdopen(workload_fd, encoding="utf-8") as handle:
        workload = json.load(handle)
    names = [entry["name"] for entry in workload["secrets"]]
    if names != sorted(set(names)) or any(not NAME.fullmatch(name) for name in names):
        raise ValueError("workload secret declarations are invalid")

    project_fd = os.open(project_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    project_state = os.fstat(project_fd)
    if not stat.S_ISDIR(project_state.st_mode) or project_state.st_uid != authority_uid \
            or project_state.st_gid != authority_gid \
            or (project_state.st_mode & 0o022):
        raise ValueError("project authority is invalid")
    source_fd = os.open("secrets", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=project_fd)
    source_before = os.fstat(source_fd)
    if not stat.S_ISDIR(source_before.st_mode) \
            or (source_before.st_mode & 0o777) != 0o700 \
            or source_before.st_uid != authority_uid \
            or source_before.st_gid != authority_gid \
            or any(name not in os.listdir(source_fd) for name in names):
        raise ValueError("managed secret authority is invalid")

    runtime_fd = os.open("runtime", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                         dir_fd=project_fd)
    runtime_state = os.fstat(runtime_fd)
    if not stat.S_ISDIR(runtime_state.st_mode) or runtime_state.st_uid != authority_uid \
            or runtime_state.st_gid != authority_gid \
            or (runtime_state.st_mode & 0o022):
        raise ValueError("runtime authority is invalid")
    try:
        os.mkdir("workload-secrets", 0o700, dir_fd=runtime_fd)
    except FileExistsError:
        pass
    secret_parent_fd = os.open(
        "workload-secrets", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=runtime_fd)
    secret_parent_state = os.fstat(secret_parent_fd)
    if not stat.S_ISDIR(secret_parent_state.st_mode) \
            or (secret_parent_state.st_mode & 0o777) != 0o700 \
            or secret_parent_state.st_uid != authority_uid \
            or secret_parent_state.st_gid != authority_gid:
        raise ValueError("runtime secret parent authority is invalid")

    temporary = f".next.{secrets.token_hex(16)}"
    os.mkdir(temporary, 0o700, dir_fd=secret_parent_fd)
    CLEANUP = (secret_parent_fd, temporary)
    temporary_fd = os.open(
        temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=secret_parent_fd)
    seen, total = set(), 0
    for name in names:
        source_secret = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_fd)
        before = os.fstat(source_secret)
        inode = (before.st_dev, before.st_ino)
        if not stat.S_ISREG(before.st_mode) or (before.st_mode & 0o777) != 0o600 \
                or before.st_uid != authority_uid or before.st_gid != authority_gid \
                or not 0 < before.st_size <= 1048576 or inode in seen:
            raise ValueError("managed secret file authority is invalid")
        seen.add(inode)
        total += before.st_size
        if total > 8388608:
            raise ValueError("managed secret set is oversized")
        output = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o444, dir_fd=temporary_fd)
        os.fchmod(output, 0o444)
        remaining = before.st_size
        while remaining:
            chunk = os.read(source_secret, min(65536, remaining))
            if not chunk:
                raise ValueError("managed secret was truncated")
            write_all(output, chunk)
            remaining -= len(chunk)
        os.fsync(output)
        os.close(output)
        if identity(os.fstat(source_secret)) != identity(before):
            raise ValueError("managed secret changed during materialization")
        os.close(source_secret)
    if identity(os.fstat(source_fd)) != identity(source_before):
        raise ValueError("managed secret directory changed during materialization")
    os.fsync(temporary_fd)

    test_failure = os.environ.get("VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL", "") \
        if authority_uid != 0 else ""
    if test_failure == "before-activate":
        raise ValueError("injected runtime secret activation failure")
    if test_failure == "pause-before-activate":
        marker = ".runtime-secrets-test-ready"
        marker_fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                            0o600, dir_fd=secret_parent_fd)
        os.close(marker_fd)
        time.sleep(0.2)
        os.unlink(marker, dir_fd=secret_parent_fd)
    if binding(os.stat("secrets", dir_fd=project_fd, follow_symlinks=False)) \
            != binding(source_before):
        raise ValueError("managed secret binding changed during materialization")
    if generation_matches(
            secret_parent_fd, temporary_fd, names, authority_uid, authority_gid):
        os.close(temporary_fd)
        remove_directory(secret_parent_fd, temporary)
        CLEANUP = None
        os.fsync(secret_parent_fd)
        os.close(secret_parent_fd)
        os.close(runtime_fd)
        os.close(source_fd)
        os.close(project_fd)
        return False
    os.close(temporary_fd)

    try:
        os.stat("previous", dir_fd=secret_parent_fd, follow_symlinks=False)
        remove_directory(secret_parent_fd, "previous")
    except FileNotFoundError:
        pass
    had_current = True
    try:
        os.rename("current", "previous", src_dir_fd=secret_parent_fd,
                  dst_dir_fd=secret_parent_fd)
    except FileNotFoundError:
        had_current = False
    activated = False
    try:
        os.rename(temporary, "current", src_dir_fd=secret_parent_fd,
                  dst_dir_fd=secret_parent_fd)
        activated = True
        if test_failure == "final-fsync":
            raise OSError("injected final fsync failure")
        os.fsync(secret_parent_fd)
    except Exception:
        if activated:
            os.rename("current", temporary, src_dir_fd=secret_parent_fd,
                      dst_dir_fd=secret_parent_fd)
        if had_current:
            os.rename("previous", "current", src_dir_fd=secret_parent_fd,
                      dst_dir_fd=secret_parent_fd)
        raise
    CLEANUP = None
    if had_current:
        try:
            if test_failure == "cleanup":
                raise OSError("injected old-set cleanup failure")
            remove_directory(secret_parent_fd, "previous")
            os.fsync(secret_parent_fd)
        except Exception:
            pass
    os.close(secret_parent_fd)
    os.close(runtime_fd)
    os.close(source_fd)
    os.close(project_fd)
    return True


if __name__ == "__main__":
    try:
        changed = main()
    except Exception:
        if CLEANUP is not None:
            try:
                remove_directory(*CLEANUP)
            except Exception:
                pass
        print("runtime secret materialization failed", file=sys.stderr)
        sys.exit(1)
    if changed is False:
        sys.exit(UNCHANGED)
