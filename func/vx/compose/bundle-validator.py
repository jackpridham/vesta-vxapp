#!/usr/bin/env python3
"""Strict parser for the schema-1 protected workload bundle wire format."""

import binascii
import gzip
import hashlib
import json
import os
import re
import stat
import struct
import sys
import zlib

NAMES = ["compose.yaml", "manifest.sha256", "workload.json"]
LIMITS = {"compose.yaml": 1048576, "manifest.sha256": 256,
          "workload.json": 262144}
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
IMAGE_ID = re.compile(r"^sha256:[a-f0-9]{64}$")


def fail(message):
    raise ValueError(message)


def pairs_unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("workload JSON contains a duplicate key")
        result[key] = value
    return result


def exact_keys(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        fail(f"{label} fields are invalid")


def slug(value, label):
    if not isinstance(value, str) or not SLUG.fullmatch(value):
        fail(f"{label} is invalid")


def validate_manifest(data):
    exact_keys(data, ["schema", "workload", "profile", "image", "services",
                      "resources", "ports", "secrets", "volumes",
                      "health_timeout_seconds", "probes", "compatibility"],
               "workload")
    if data["schema"] != 1 or isinstance(data["schema"], bool):
        fail("workload schema is unsupported")
    exact_keys(data["workload"], ["id", "release"], "workload identity")
    slug(data["workload"]["id"], "workload id")
    release = data["workload"]["release"]
    if not isinstance(release, str) or not 1 <= len(release.encode()) <= 128 \
            or any(ord(c) < 32 or ord(c) > 126 for c in release):
        fail("release is invalid")
    exact_keys(data["profile"], ["name", "version"], "profile")
    slug(data["profile"]["name"], "profile name")
    if not isinstance(data["profile"]["version"], int) \
            or isinstance(data["profile"]["version"], bool) \
            or data["profile"]["version"] < 1:
        fail("profile version is invalid")
    exact_keys(data["image"], ["reference", "id", "os", "architecture"], "image")
    if not isinstance(data["image"]["reference"], str) \
            or not 1 <= len(data["image"]["reference"].encode()) <= 255:
        fail("image reference is invalid")
    if not isinstance(data["image"]["id"], str) or not IMAGE_ID.fullmatch(data["image"]["id"]):
        fail("image id is invalid")
    for field in ("os", "architecture"):
        slug(data["image"][field], f"image {field}")
    services = data["services"]
    if not isinstance(services, list) or not services:
        fail("services are invalid")
    service_ids = []
    for service in services:
        exact_keys(service, ["name", "image"], "service")
        slug(service["name"], "service name")
        if service["image"] != data["image"]["reference"]:
            fail("service image intent does not match")
        service_ids.append(service["name"])
    if service_ids != sorted(set(service_ids)):
        fail("services are duplicated or unsorted")
    exact_keys(data["resources"], ["cpus", "memory_mib", "pids"], "resources")
    if not isinstance(data["resources"]["cpus"], str) \
            or not re.fullmatch(r"[0-9]+\.[0-9]{3}", data["resources"]["cpus"]):
        fail("resource cpus are invalid")
    for field in ("memory_mib", "pids"):
        if not isinstance(data["resources"][field], int) \
                or isinstance(data["resources"][field], bool) \
                or data["resources"][field] < 1:
            fail(f"resource {field} is invalid")
    stable = []
    for port in data["ports"]:
        exact_keys(port, ["service", "host_ip", "host_port", "container_port", "protocol"], "port")
        if port["service"] not in service_ids or port["protocol"] not in ("tcp", "udp"):
            fail("port declaration is invalid")
        if not isinstance(port["host_ip"], str) or not port["host_ip"]:
            fail("port host ip is invalid")
        for field in ("host_port", "container_port"):
            if not isinstance(port[field], int) or isinstance(port[field], bool) or not 1 <= port[field] <= 65535:
                fail("port number is invalid")
        stable.append((port["service"], port["host_ip"], port["host_port"], port["container_port"], port["protocol"]))
    if stable != sorted(set(stable)):
        fail("ports are duplicated or unsorted")
    for field, keys in (("secrets", ["name", "target"]),
                        ("volumes", ["name", "service", "target"])):
        identities = []
        for item in data[field]:
            exact_keys(item, keys, field[:-1])
            slug(item["name"], f"{field[:-1]} name")
            if "service" in item and item["service"] not in service_ids:
                fail("volume service is invalid")
            if not isinstance(item["target"], str) or not item["target"].startswith("/") \
                    or ".." in item["target"].split("/"):
                fail(f"{field[:-1]} target is invalid")
            identities.append(tuple(item[key] for key in keys))
        if identities != sorted(set(identities)):
            fail(f"{field} are duplicated or unsorted")
    if not isinstance(data["health_timeout_seconds"], int) \
            or isinstance(data["health_timeout_seconds"], bool) \
            or not 1 <= data["health_timeout_seconds"] <= 900:
        fail("health timeout is invalid")
    if not isinstance(data["probes"], dict):
        fail("probes are invalid")
    for name in sorted(data["probes"]):
        slug(name, "probe name")
        probe = data["probes"][name]
        exact_keys(probe, ["service", "argv", "timeout_seconds", "max_output_bytes"], "probe")
        if probe["service"] not in service_ids:
            fail("probe service is invalid")
        argv = probe["argv"]
        if not isinstance(argv, list) or not 1 <= len(argv) <= 16:
            fail("probe argv is invalid")
        total = 0
        for arg in argv:
            if not isinstance(arg, str) or not 1 <= len(arg.encode()) <= 256 \
                    or any(ord(c) < 32 or ord(c) == 127 for c in arg):
                fail("probe argv is invalid")
            total += len(arg.encode())
        if not argv[0].startswith("/") or total > 2048:
            fail("probe argv is invalid")
        if not isinstance(probe["timeout_seconds"], int) or isinstance(probe["timeout_seconds"], bool) \
                or not 1 <= probe["timeout_seconds"] <= 60:
            fail("probe timeout is invalid")
        if not isinstance(probe["max_output_bytes"], int) or isinstance(probe["max_output_bytes"], bool) \
                or not 256 <= probe["max_output_bytes"] <= 8192:
            fail("probe output limit is invalid")
    exact_keys(data["compatibility"], ["orchestrator_api", "policy_schema", "validator_min", "validator_max"], "compatibility")
    comp = data["compatibility"]
    if any(not isinstance(comp[k], int) or isinstance(comp[k], bool) or comp[k] < 1 for k in comp) \
            or comp["validator_min"] > comp["validator_max"]:
        fail("workload compatibility is unsupported")


def octal(field):
    if not re.fullmatch(rb"[0-7 ]+(?:\0 ?| )", field):
        fail("ustar numeric field is invalid")
    return int(field.rstrip(b"\0 ").lstrip(b" ") or b"0", 8)


def parse_bundle(archive, checksum, output):
    basename = os.path.basename(archive)
    authority_uid, authority_gid = os.geteuid(), os.getegid()
    archive_fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW)
    checksum_fd = os.open(checksum, os.O_RDONLY | os.O_NOFOLLOW)
    archive_before, checksum_before = os.fstat(archive_fd), os.fstat(checksum_fd)
    for state in (archive_before, checksum_before):
        if not stat.S_ISREG(state.st_mode) or (state.st_mode & 0o777) != 0o600 \
                or state.st_uid != authority_uid or state.st_gid != authority_gid:
            fail("bundle input authority is invalid")
    with os.fdopen(checksum_fd, "rb", closefd=False) as handle:
        wanted = handle.read(1024)
    match = re.fullmatch(rb"([a-f0-9]{64})  " + re.escape(basename.encode()) + rb"\n", wanted)
    if not match:
        fail("bundle checksum file is invalid")
    with os.fdopen(archive_fd, "rb", closefd=False) as handle:
        raw = handle.read(67108865)
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid,
                          s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if identity(os.fstat(archive_fd)) != identity(archive_before) \
            or identity(os.fstat(checksum_fd)) != identity(checksum_before):
        fail("bundle input identity changed during validation")
    os.close(archive_fd); os.close(checksum_fd)
    if len(raw) > 67108864 or hashlib.sha256(raw).hexdigest().encode() != match.group(1):
        fail("bundle checksum does not match")
    if raw[:10] != bytes.fromhex("1f8b0800000000000203") or len(raw) < 18:
        fail("gzip header is not deterministic")
    stream = zlib.decompressobj(-15)
    expanded = stream.decompress(raw[10:-8], 4194305) + stream.flush()
    if not stream.eof or stream.unused_data or len(expanded) > 4194304:
        fail("gzip stream is invalid")
    crc, size = struct.unpack("<II", raw[-8:])
    if crc != binascii.crc32(expanded) & 0xffffffff or size != len(expanded) & 0xffffffff:
        fail("gzip trailer is invalid")
    pos, members = 0, {}
    for expected in NAMES:
        header = expanded[pos:pos + 512]
        if len(header) != 512 or header == bytes(512):
            fail("ustar member table is incomplete")
        stored = octal(header[148:156])
        check_header = bytearray(header); check_header[148:156] = b"        "
        if sum(check_header) != stored or header[257:263] != b"ustar\0" or header[263:265] != b"00":
            fail("ustar header is invalid")
        name = header[:100].split(b"\0", 1)[0].decode("ascii")
        size_value = octal(header[124:136])
        canonical_checksum = f"{stored:06o}\0 ".encode()
        if name != expected or header[100:108] != b"0000600\0" \
                or header[108:116] != b"0000000\0" or header[116:124] != b"0000000\0" \
                or header[124:136] != f"{size_value:011o}\0".encode() \
                or header[136:148] != b"00000000000\0" \
                or header[148:156] != canonical_checksum \
                or octal(header[100:108]) != 0o600 or octal(header[108:116]) != 0 \
                or octal(header[116:124]) != 0 or octal(header[136:148]) != 0 \
                or header[156:157] not in (b"0", b"\0") or header[157:257].strip(b"\0") \
                or header[265:297].strip(b"\0") or header[297:329].strip(b"\0") \
                or header[329:337].strip(b"\0") or header[337:345].strip(b"\0") \
                or header[345:500].strip(b"\0") or header[500:512].strip(b"\0") \
                or size_value > LIMITS[name]:
            fail("ustar member authority is invalid")
        pos += 512
        members[name] = expanded[pos:pos + size_value]
        if len(members[name]) != size_value:
            fail("ustar member is truncated")
        padded = ((size_value + 511) // 512) * 512
        if expanded[pos + size_value:pos + padded] != bytes(padded - size_value):
            fail("ustar member padding is invalid")
        pos += padded
    if expanded[pos:] != bytes(1024) or sum(map(len, members.values())) > 2097152:
        fail("ustar ending or size is invalid")
    expected_manifest = (hashlib.sha256(members["workload.json"]).hexdigest() + "  workload.json\n" +
                         hashlib.sha256(members["compose.yaml"]).hexdigest() + "  compose.yaml\n").encode()
    if members["manifest.sha256"] != expected_manifest:
        fail("bundle member manifest is invalid")
    try:
        workload = json.loads(members["workload.json"].decode("utf-8"), object_pairs_hook=pairs_unique,
                              parse_float=lambda _: fail("non-integer JSON number"),
                              parse_constant=lambda _: fail("invalid JSON number"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"workload JSON is invalid: {exc}")
    canonical = (json.dumps(workload, ensure_ascii=False, sort_keys=True,
                            separators=(",", ":")) + "\n").encode()
    if canonical != members["workload.json"]:
        fail("workload JSON is not canonical")
    validate_manifest(workload)
    os.mkdir(output, 0o700)
    for name in NAMES:
        path = os.path.join(output, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(members[name])
    evidence = {"ARCHIVE_SHA256": hashlib.sha256(raw).hexdigest(),
                "COMPOSE_SHA256": hashlib.sha256(members["compose.yaml"]).hexdigest(),
                "MANIFEST_SHA256": hashlib.sha256(members["manifest.sha256"]).hexdigest(),
                "WORKLOAD_SHA256": hashlib.sha256(members["workload.json"]).hexdigest()}
    path = os.path.join(output, "workload-evidence.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, sort_keys=True, separators=(",", ":")); handle.write("\n")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "workload":
            fd = os.open(sys.argv[2], os.O_RDONLY | os.O_NOFOLLOW)
            state = os.fstat(fd)
            if not stat.S_ISREG(state.st_mode) or (state.st_mode & 0o777) != 0o600 \
                    or state.st_uid != os.geteuid() or state.st_gid != os.getegid():
                fail("workload authority is invalid")
            with os.fdopen(fd, "rb") as handle:
                raw = handle.read(262145)
            value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs_unique,
                               parse_float=lambda _: fail("non-integer JSON number"),
                               parse_constant=lambda _: fail("invalid JSON number"))
            if (json.dumps(value, ensure_ascii=False, sort_keys=True,
                           separators=(",", ":")) + "\n").encode() != raw:
                fail("workload JSON is not canonical")
            validate_manifest(value)
        else:
            parse_bundle(sys.argv[1], sys.argv[2], sys.argv[3])
    except (ValueError, OSError, IndexError) as exc:
        print(f"workload bundle rejected: {exc}", file=sys.stderr)
        sys.exit(1)
