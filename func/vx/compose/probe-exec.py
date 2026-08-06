#!/usr/bin/env python3
"""Run one Docker Engine exec through the local Unix API with a retained ID."""

import json
import os
import socket
import struct
import sys
import time

SOCKET = os.environ.get("VX_COMPOSE_PROBE_TEST_SOCKET", "/var/run/docker.sock")
API = "/v1.41"


def connect(timeout):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    client.connect(SOCKET)
    return client


def request(method, path, body, timeout):
    encoded = json.dumps(body, separators=(",", ":")).encode() if body is not None else b""
    client = connect(timeout)
    headers = (f"{method} {API}{path} HTTP/1.1\r\nHost: localhost\r\n"
               f"Content-Type: application/json\r\nContent-Length: {len(encoded)}\r\n"
               "Connection: close\r\n\r\n").encode()
    client.sendall(headers + encoded)
    data = b""
    while b"\r\n\r\n" not in data:
        part = client.recv(4096)
        if not part:
            raise RuntimeError("engine response ended before headers")
        data += part
        if len(data) > 65536:
            raise RuntimeError("engine response headers are oversized")
    header, initial = data.split(b"\r\n\r\n", 1)
    status = int(header.split(b" ", 2)[1])
    return client, status, header, initial


def read_response(method, path, body, timeout, limit=65536):
    client, status, _, data = request(method, path, body, timeout)
    try:
        while True:
            part = client.recv(4096)
            if not part:
                break
            data += part
            if len(data) > limit:
                raise RuntimeError("engine response is oversized")
    finally:
        client.close()
    if status < 200 or status >= 300:
        raise RuntimeError(f"engine request failed with status {status}")
    return json.loads(data.decode("utf-8"))


def exact_read(client, pending, count):
    while len(pending) < count:
        part = client.recv(min(65536, count - len(pending)))
        if not part:
            return None, pending
        pending += part
    return pending[:count], pending[count:]


def start_exec(exec_id, deadline, output_limit, stdout_path, stderr_path):
    remaining = max(0.1, deadline - time.monotonic())
    client, status, _, pending = request(
        "POST", f"/exec/{exec_id}/start", {"Detach": False, "Tty": False}, remaining)
    if status < 200 or status >= 300:
        client.close()
        raise RuntimeError(f"engine exec start failed with status {status}")
    sizes = [0, 0, 0]
    total = 0
    truncated = False
    timed_out = False
    try:
        with open(stdout_path, "wb", buffering=0) as stdout, \
                open(stderr_path, "wb", buffering=0) as stderr:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                client.settimeout(remaining)
                try:
                    header, pending = exact_read(client, pending, 8)
                except socket.timeout:
                    timed_out = True
                    break
                if header is None:
                    break
                stream = header[0]
                if stream not in (1, 2) or header[1:4] != b"\0\0\0":
                    raise RuntimeError("engine exec stream framing is invalid")
                length = struct.unpack(">I", header[4:8])[0]
                if length > 1048576:
                    raise RuntimeError("engine exec frame is oversized")
                payload, pending = exact_read(client, pending, length)
                if payload is None:
                    raise RuntimeError("engine exec stream is truncated")
                prior_stream = sizes[stream]
                prior_total = total
                sizes[stream] += length
                total += length
                allowed = min(max(0, output_limit + 1 - prior_stream),
                              max(0, output_limit + 1 - prior_total))
                target = stdout if stream == 1 else stderr
                target.write(payload[:allowed])
                if sizes[stream] > output_limit or total > output_limit:
                    truncated = True
    finally:
        client.close()
    return timed_out, truncated


def main():
    if sys.argv[1] == "inspect":
        exec_id, result_path = sys.argv[2:4]
        inspected = read_response("GET", f"/exec/{exec_id}/json", None, 5)
        result = {"EXEC_ID": exec_id, "RUNNING": inspected.get("Running") is True,
                  "EXIT_CODE": inspected.get("ExitCode"), "PID": inspected.get("Pid")}
        fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(result, handle, sort_keys=True, separators=(",", ":")); handle.write("\n")
        return
    request_path, stdout_path, stderr_path, result_path = sys.argv[1:5]
    with open(request_path, encoding="utf-8") as handle:
        spec = json.load(handle)
    timeout = int(spec["timeout_seconds"])
    grace = int(spec["transport_grace_seconds"])
    output_limit = int(spec["max_output_bytes"])
    created = read_response("POST", f"/containers/{spec['container_id']}/exec", {
        "AttachStdin": False, "AttachStdout": True, "AttachStderr": True,
        "Tty": False, "Cmd": spec["argv"]}, 5)
    exec_id = created.get("Id", "")
    if not isinstance(exec_id, str) or len(exec_id) != 64 \
            or any(c not in "0123456789abcdef" for c in exec_id):
        raise RuntimeError("engine returned an invalid exec id")
    started = time.monotonic()
    timed_out, truncated = start_exec(
        exec_id, started + timeout + grace, output_limit, stdout_path, stderr_path)
    inspected = read_response("GET", f"/exec/{exec_id}/json", None, 5)
    running = inspected.get("Running") is True
    exit_code = inspected.get("ExitCode")
    declared_timeout = (time.monotonic() - started) > timeout
    pid = inspected.get("Pid")
    result = {"EXEC_ID": exec_id, "RUNNING": running,
              "PID": pid if isinstance(pid, int) and pid >= 0 else None,
              "EXIT_CODE": exit_code if isinstance(exit_code, int) else None,
              "TRANSPORT_TIMEOUT": timed_out, "DECLARED_TIMEOUT": declared_timeout,
              "TRUNCATED": truncated}
    fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(result, handle, sort_keys=True, separators=(",", ":")); handle.write("\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("probe engine execution failed", file=sys.stderr)
        sys.exit(125)
