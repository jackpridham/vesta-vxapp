#!/usr/bin/env python3
"""Snapshot protected bundle secret inputs through no-follow descriptors."""
import json, os, stat, sys, time

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_size, value.st_mtime_ns, value.st_ctime_ns)

def write_all(fd, value):
    written = 0
    while written < len(value):
        count = os.write(fd, value[written:])
        if count < 1:
            raise ValueError("secret snapshot write failed")
        written += count

def main():
    manifest_path, source_path, destination_path = sys.argv[1:4]
    manifest_fd = os.open(manifest_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(manifest_fd, encoding="utf-8") as handle:
        declared = [entry["name"] for entry in json.load(handle)["secrets"]]
    source_parent = os.path.dirname(source_path)
    source_name = os.path.basename(source_path)
    if not os.path.isabs(source_parent) or source_name in ("", ".", ".."):
        raise ValueError("secret directory path is invalid")
    grandparent = os.path.dirname(source_parent)
    parent_name = os.path.basename(source_parent)
    grandparent_fd = os.open(
        grandparent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parent_fd = os.open(
        parent_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=grandparent_fd)
    parent_before = os.fstat(parent_fd)
    if not stat.S_ISDIR(parent_before.st_mode) \
            or (parent_before.st_mode & 0o777) != 0o700 \
            or parent_before.st_uid != os.geteuid() \
            or parent_before.st_gid != os.getegid():
        raise ValueError("secret staging parent authority is invalid")
    source_fd = os.open(source_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=parent_fd)
    source_before = os.fstat(source_fd)
    if not stat.S_ISDIR(source_before.st_mode) or (source_before.st_mode & 0o777) != 0o700 \
            or source_before.st_uid != os.geteuid() or source_before.st_gid != os.getegid():
        raise ValueError("secret directory authority is invalid")
    test_pause = os.environ.get("VX_COMPOSE_BUNDLE_SECRET_TEST_PAUSE", "") \
        if os.geteuid() != 0 else ""
    if test_pause in ("parent", "directory"):
        marker_path = os.path.join(
            os.path.dirname(destination_path), ".bundle-secrets-test-ready")
        marker_fd = os.open(marker_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(marker_fd)
        time.sleep(0.2)
        os.unlink(marker_path)
    if sorted(os.listdir(source_fd)) != sorted(declared):
        raise ValueError("secret input set does not match the manifest")
    os.mkdir(destination_path, 0o700)
    os.chmod(destination_path, 0o700)
    destination_fd = os.open(destination_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    seen, total = set(), 0
    for name in declared:
        source_secret = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_fd)
        before = os.fstat(source_secret)
        file_identity = (before.st_dev, before.st_ino)
        if not stat.S_ISREG(before.st_mode) or (before.st_mode & 0o777) != 0o600 \
                or before.st_uid != os.geteuid() or before.st_gid != os.getegid() \
                or not 0 < before.st_size <= 1048576 or file_identity in seen:
            raise ValueError("secret input authority is invalid")
        seen.add(file_identity); total += before.st_size
        if total > 8388608:
            raise ValueError("aggregate secret input is oversized")
        output = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=destination_fd)
        os.fchmod(output, 0o600)
        if test_pause == "yes":
            time.sleep(0.2)
        remaining = before.st_size
        while remaining:
            chunk = os.read(source_secret, min(65536, remaining))
            if not chunk:
                raise ValueError("secret input was truncated")
            write_all(output, chunk); remaining -= len(chunk)
        os.fsync(output); os.close(output)
        if identity(os.fstat(source_secret)) != identity(before):
            raise ValueError("secret input changed during snapshot")
        os.close(source_secret)
    if identity(os.fstat(source_fd)) != identity(source_before):
        raise ValueError("secret directory changed during snapshot")
    binding = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                             value.st_uid, value.st_gid)
    if binding(os.stat(source_name, dir_fd=parent_fd, follow_symlinks=False)) \
            != binding(source_before) \
            or binding(os.stat(parent_name, dir_fd=grandparent_fd,
                               follow_symlinks=False)) != binding(parent_before):
        raise ValueError("secret staging binding changed during snapshot")
    os.fsync(destination_fd); os.close(destination_fd); os.close(source_fd)
    os.close(parent_fd); os.close(grandparent_fd)

if __name__ == "__main__":
    try: main()
    except Exception:
        print("protected secret snapshot failed", file=sys.stderr); sys.exit(1)
