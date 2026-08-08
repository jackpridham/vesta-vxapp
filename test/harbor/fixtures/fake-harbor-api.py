#!/usr/bin/env python3
"""Deterministic, loopback-only Harbor API fixture."""

import argparse
import base64
import json
import os
import re
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

MAX_BODY = 1024 * 1024


def initial_state():
    return {
        "configurations": {},
        "projects": [],
        "quotas": [],
        "robots": [],
        "artifacts": {},
        "volumes": {"storage": {"total": 0, "free": 0}},
        "next_project_id": 1,
        "next_quota_id": 1,
        "next_robot_id": 1,
    }


class StateStore:
    def __init__(self, path):
        self.path = path
        if not os.path.exists(path):
            self.write(initial_state())

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)

    def write(self, value):
        directory = os.path.dirname(os.path.abspath(self.path))
        fd, temporary = tempfile.mkstemp(prefix=".fake-harbor.", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(value, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


class HarborHandler(BaseHTTPRequestHandler):
    server_version = "fake-harbor"
    sys_version = ""

    def log_message(self, _format, *_args):
        return

    def finish_status(self, status, payload=None, headers=None):
        body = b""
        if payload is not None:
            body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        self.server.log_handle.write(f"{self.command} {urlsplit(self.path).path} {status}\n")
        self.server.log_handle.flush()

    def authenticated(self):
        expected = base64.b64encode(
            f"{self.server.username}:{self.server.password}".encode()
        ).decode()
        return self.headers.get("Authorization") == f"Basic {expected}"

    def bounded_content_length(self):
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except ValueError:
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        if length < 0:
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        if length > MAX_BODY:
            self.finish_status(413, {"errors": [{"code": "PAYLOAD_TOO_LARGE"}]})
            return None
        return length

    def read_json(self):
        length = self.bounded_content_length()
        if length is None:
            return None
        body = self.rfile.read(length)
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        if not isinstance(value, dict):
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        return value

    @staticmethod
    def find(items, key):
        return next(
            (item for item in items if str(item.get("id")) == key or item.get("name") == key),
            None,
        )

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def unsupported_method(self):
        if self.bounded_content_length() is None:
            return
        self.finish_status(404)

    def do_HEAD(self):
        self.unsupported_method()

    def do_PATCH(self):
        self.unsupported_method()

    def do_OPTIONS(self):
        self.unsupported_method()

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.unsupported_method
        raise AttributeError(name)

    def dispatch(self):
        path = unquote(urlsplit(self.path).path)
        if self.bounded_content_length() is None:
            return
        if not self.authenticated():
            headers = {"WWW-Authenticate": 'Basic realm="harbor"'}
            if path == "/v2/":
                headers["Docker-Distribution-Api-Version"] = "registry/2.0"
            self.finish_status(401, {"errors": [{"code": "UNAUTHORIZED"}]}, headers)
            return

        state = self.server.store.read()
        method = self.command

        if path == "/api/v2.0/configurations" and method in ("GET", "PUT"):
            if method == "PUT":
                body = self.read_json()
                if body is None:
                    return
                state["configurations"].update(body)
                self.server.store.write(state)
                self.finish_status(200)
            else:
                self.finish_status(200, state["configurations"])
            return
        if path == "/api/v2.0/health" and method == "GET":
            self.finish_status(200, {"status": "healthy", "components": []})
            return
        if path == "/api/v2.0/systeminfo/volumes" and method == "GET":
            self.finish_status(200, state["volumes"])
            return
        if path == "/v2/" and method == "GET":
            self.finish_status(200, headers={"Docker-Distribution-Api-Version": "registry/2.0"})
            return
        if path == "/service/token" and method == "GET":
            self.finish_status(200, {"token": "fake-token", "expires_in": 300})
            return
        if path == "/api/v2.0/projects" and method in ("GET", "POST"):
            if method == "GET":
                self.finish_status(200, state["projects"])
                return
            body = self.read_json()
            if body is None:
                return
            name = body.get("project_name") or body.get("name")
            if not isinstance(name, str) or not name:
                self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                return
            if self.find(state["projects"], name):
                self.finish_status(409, {"errors": [{"code": "CONFLICT"}]})
                return
            project_id = state["next_project_id"]
            quota_id = state["next_quota_id"]
            state["next_project_id"] += 1
            state["next_quota_id"] += 1
            project = {"id": project_id, "name": name, "project_id": project_id,
                       "metadata": body.get("metadata", {"public": "false"}),
                       "quota_id": quota_id}
            state["projects"].append(project)
            state["quotas"].append({"id": quota_id, "ref": {"id": project_id},
                                     "hard": {"storage": -1}, "used": {"storage": 0}})
            self.server.store.write(state)
            self.finish_status(201, headers={"Location": f"/api/v2.0/projects/{project_id}"})
            return

        project_match = re.fullmatch(r"/api/v2\.0/projects/([^/]+)", path)
        if project_match and method in ("GET", "PUT"):
            project = self.find(state["projects"], project_match.group(1))
            if not project:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if method == "PUT":
                body = self.read_json()
                if body is None:
                    return
                project.update({key: value for key, value in body.items() if key not in ("id", "project_id")})
                self.server.store.write(state)
                self.finish_status(200)
            else:
                self.finish_status(200, project)
            return

        quota_match = re.fullmatch(r"/api/v2\.0/quotas/(\d+)", path)
        if quota_match and method in ("GET", "PUT"):
            quota = self.find(state["quotas"], quota_match.group(1))
            if not quota:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if method == "PUT":
                body = self.read_json()
                if body is None:
                    return
                quota.update(body)
                self.server.store.write(state)
                self.finish_status(200)
            else:
                self.finish_status(200, quota)
            return

        if path == "/api/v2.0/robots" and method in ("GET", "POST"):
            if method == "GET":
                self.finish_status(200, state["robots"])
                return
            body = self.read_json()
            if body is None:
                return
            robot_id = state["next_robot_id"]
            state["next_robot_id"] += 1
            robot = dict(body)
            robot["id"] = robot_id
            robot.setdefault("disabled", False)
            state["robots"].append(robot)
            self.server.store.write(state)
            self.finish_status(201, robot)
            return

        robot_match = re.fullmatch(r"/api/v2\.0/robots/(\d+)", path)
        if robot_match and method in ("GET", "PUT", "DELETE"):
            robot = self.find(state["robots"], robot_match.group(1))
            if not robot:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if method == "GET":
                self.finish_status(200, robot)
            elif method == "DELETE":
                state["robots"].remove(robot)
                self.server.store.write(state)
                self.finish_status(200)
            else:
                body = self.read_json()
                if body is None:
                    return
                robot.update({key: value for key, value in body.items() if key != "id"})
                self.server.store.write(state)
                self.finish_status(200)
            return

        repositories = re.fullmatch(r"/api/v2\.0/projects/([^/]+)/repositories", path)
        if repositories and method == "GET":
            project = repositories.group(1)
            names = sorted({key.split("@", 1)[0] for key in state["artifacts"]
                            if key.startswith(project + "/")})
            self.finish_status(200, [{"name": name} for name in names])
            return

        artifact = re.fullmatch(
            r"/api/v2\.0/projects/([^/]+)/repositories/(.+)/artifacts/([^/]+)", path
        )
        if artifact and method == "GET":
            key = f"{artifact.group(1)}/{artifact.group(2)}@{artifact.group(3)}"
            value = state["artifacts"].get(key)
            if value is None:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
            else:
                self.finish_status(200, value)
            return

        self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--state", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--username", default="integration")
    parser.add_argument("--password", default="integration-secret")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")

    with open(args.log, "a", encoding="utf-8", buffering=1) as log_handle:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), HarborHandler)
        server.store = StateStore(args.state)
        server.log_handle = log_handle
        server.username = args.username
        server.password = args.password
        server.serve_forever()


if __name__ == "__main__":
    main()
