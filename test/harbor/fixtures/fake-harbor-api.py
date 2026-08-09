#!/usr/bin/env python3
"""Deterministic, loopback-only Harbor API fixture."""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import socketserver
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit


class ThreadingUnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        return

MAX_BODY = 1024 * 1024
BODY_READ_TIMEOUT = 0.5

SYSTEM_ROBOT_CATALOG = {
    ("project", "create"),
    ("project", "list"),
    ("quota", "list"),
    ("quota", "read"),
    ("quota", "update"),
    ("robot", "create"),
    ("robot", "delete"),
    ("robot", "list"),
    ("robot", "read"),
    ("system-volumes", "read"),
}
PROJECT_ROBOT_CATALOG = {
    ("artifact", "read"),
    ("project", "read"),
    ("project", "update"),
    ("quota", "read"),
    ("repository", "list"),
    ("repository", "pull"),
    ("repository", "push"),
    ("repository", "read"),
    ("robot", "create"),
    ("robot", "delete"),
    ("robot", "list"),
    ("robot", "read"),
}


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
        "fault": None,
    }


def generated_robot_secret(robot_id):
    """Return a valid, deterministic fixture-only Harbor-style secret."""
    digest = hashlib.sha256(f"fake-harbor-robot-{robot_id}".encode()).digest()
    encoded = base64.urlsafe_b64encode(digest).decode().rstrip("=")
    return encoded[:40] + "Aa0"


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
        if getattr(self, "defer_response", False):
            self.deferred_response = (status, payload, headers)
            return
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
        with self.server.log_lock:
            self.server.log_handle.write(
                f"{self.command} {urlsplit(self.path).path} {status}\n"
            )
            self.server.log_handle.flush()

    @staticmethod
    def public_robot(robot):
        public = {
            key: value
            for key, value in robot.items()
            if key not in ("disabled", "project_id", "secret", "stored_name")
        }
        public["disable"] = bool(robot.get("disabled", False))
        return public

    def robot_list_scope(self, state):
        query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        allowed = {"q", "page", "page_size"}
        if set(query) - allowed or any(len(values) != 1 for values in query.values()):
            return None
        page = query.get("page", ["1"])[0]
        if not page.isdigit() or not 1 <= int(page) <= 1000:
            return None
        page_size = query.get("page_size", ["10"])[0]
        if not page_size.isdigit() or not 1 <= int(page_size) <= 100:
            return None
        expression = query.get("q", ["Level=system"])[0]
        if expression == "Level=system":
            return "system", 0, int(page), int(page_size)
        match = re.fullmatch(r"Level=project,ProjectID=([1-9][0-9]*)", expression)
        if not match:
            return None
        project_id = int(match.group(1))
        if not self.find(state["projects"], str(project_id)):
            return None
        return "project", project_id, int(page), int(page_size)

    def authenticate(self):
        supplied = self.headers.get("Authorization")
        bootstrap = "Basic " + base64.b64encode(
            f"{self.server.username}:{self.server.password}".encode()
        ).decode()
        if supplied == bootstrap:
            return {"kind": "bootstrap", "name": self.server.username}
        state = self.server.store.read()
        for robot in state["robots"]:
            username = robot.get("name")
            password = robot.get("secret")
            if robot.get("disabled") or not username or not password:
                continue
            expected = "Basic " + base64.b64encode(
                f"{username}:{password}".encode()
            ).decode()
            if supplied == expected:
                return {"kind": "robot", "name": username, "robot": robot}
        return None

    def is_bootstrap(self):
        return self.actor["kind"] == "bootstrap"

    def can(self, kind, namespace, resource, action):
        if self.is_bootstrap():
            return True
        for permission in self.actor["robot"].get("permissions", []):
            if permission.get("kind") != kind:
                continue
            creator_namespace = permission.get("namespace")
            if creator_namespace != namespace and creator_namespace != "*":
                continue
            if any(
                access.get("resource") == resource and access.get("action") == action
                for access in permission.get("access", [])
            ):
                return True
        return False

    def require(self, kind, namespace, resource, action):
        if self.can(kind, namespace, resource, action):
            return True
        self.finish_status(403, {"errors": [{"code": "FORBIDDEN"}]})
        return False

    @staticmethod
    def permission_subset(creating, creator):
        for permission in creating:
            matching = next(
                (
                    candidate
                    for candidate in creator
                    if candidate.get("kind") == permission.get("kind")
                    and candidate.get("namespace")
                    in (permission.get("namespace"), "*")
                ),
                None,
            )
            if matching is None:
                return False
            creator_access = {
                (access.get("resource"), access.get("action"))
                for access in matching.get("access", [])
            }
            if any(
                (access.get("resource"), access.get("action")) not in creator_access
                for access in permission.get("access", [])
            ):
                return False
        return True

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

    def read_bounded_body(self):
        length = self.bounded_content_length()
        if length is None:
            return False
        self.request_body = b""
        if length == 0:
            return True
        previous_timeout = self.connection.gettimeout()
        self.connection.settimeout(BODY_READ_TIMEOUT)
        try:
            while len(self.request_body) < length:
                chunk = self.rfile.read(length - len(self.request_body))
                if not chunk:
                    self.finish_status(408, {"errors": [{"code": "REQUEST_TIMEOUT"}]})
                    return False
                self.request_body += chunk
        except (TimeoutError, socket.timeout):
            self.finish_status(408, {"errors": [{"code": "REQUEST_TIMEOUT"}]})
            return False
        finally:
            self.connection.settimeout(previous_timeout)
        return True

    def read_json(self):
        if hasattr(self, "request_json"):
            return self.request_json
        try:
            value = json.loads(self.request_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        if not isinstance(value, dict):
            self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
            return None
        self.request_json = value
        return value

    @staticmethod
    def expects_json(method, path):
        if method == "PUT" and path == "/api/v2.0/configurations":
            return True
        if method == "POST" and path in ("/api/v2.0/projects", "/api/v2.0/robots"):
            return True
        if method in ("PUT", "PATCH") and re.fullmatch(
            r"/api/v2\.0/(projects/[^/]+|quotas/\d+|robots/\d+)", path
        ):
            return True
        return False

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

    def do_PATCH(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def unsupported_method(self):
        if not self.read_bounded_body():
            return
        self.finish_status(404)

    def do_HEAD(self):
        self.unsupported_method()

    def do_OPTIONS(self):
        self.unsupported_method()

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.unsupported_method
        raise AttributeError(name)

    def dispatch(self):
        path = unquote(urlsplit(self.path).path)
        method = self.command
        if not self.read_bounded_body():
            return
        self.actor = self.authenticate()
        if self.actor is None:
            headers = {"WWW-Authenticate": 'Basic realm="harbor"'}
            if path == "/v2/":
                headers["Docker-Distribution-Api-Version"] = "registry/2.0"
            self.finish_status(401, {"errors": [{"code": "UNAUTHORIZED"}]}, headers)
            return

        fault = self.server.store.read().get("fault")
        fault_matches = (
            isinstance(fault, dict)
            and fault.get("path") == path
            and fault.get("method", method) == method
        )
        if fault_matches and fault.get("mode") != "lost-response":
            status = fault.get("status", 200)
            if fault.get("mode") == "delay":
                time.sleep(float(fault.get("seconds", 1)))
            elif fault.get("mode") == "malformed":
                body = b"{malformed"
            elif fault.get("mode") == "oversize":
                body = b"x" * (MAX_BODY + 1)
            elif fault.get("mode") != "delay":
                self.finish_status(status, {"errors": [{"code": "INJECTED"}]})
                return
            if fault.get("mode") != "delay":
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

        if path == "/api/v2.0/health" and method == "GET":
            self.finish_status(200, {"status": "healthy", "components": []})
            return
        if path == "/v2/" and method == "GET":
            self.finish_status(200, headers={"Docker-Distribution-Api-Version": "registry/2.0"})
            return
        if path == "/service/token" and method == "GET":
            self.finish_status(200, {"token": "fake-token", "expires_in": 300})
            return
        if self.expects_json(method, path) and self.read_json() is None:
            return

        self.defer_response = True
        self.deferred_response = None
        try:
            with self.server.state_lock:
                self.dispatch_state(path, method)
        finally:
            self.defer_response = False
        if self.deferred_response is None:
            raise RuntimeError("state dispatch did not produce a response")
        if fault_matches and fault.get("mode") == "lost-response":
            self.close_connection = True
            with self.server.log_lock:
                self.server.log_handle.write(f"{method} {path} 000\n")
                self.server.log_handle.flush()
            return
        self.finish_status(*self.deferred_response)

    @staticmethod
    def robot_prefix(state):
        value = state.get("configurations", {}).get("robot_name_prefix", "robot$")
        if isinstance(value, dict):
            value = value.get("value")
        return value if isinstance(value, str) and value else "robot$"

    @staticmethod
    def private_metadata(value):
        return isinstance(value, dict) and value == {"public": "false"}

    @staticmethod
    def validate_permissions(level, permissions, state):
        if level not in ("system", "project") or not isinstance(permissions, list):
            return False
        if not permissions or (level == "project" and len(permissions) != 1):
            return False
        for permission in permissions:
            if not isinstance(permission, dict):
                return False
            kind = permission.get("kind")
            namespace = permission.get("namespace")
            access = permission.get("access")
            if kind not in ("system", "project") or not isinstance(access, list) or not access:
                return False
            if kind == "system" and namespace != "/":
                return False
            if kind == "project" and namespace != "*" and not HarborHandler.find(
                state["projects"], str(namespace)
            ):
                return False
            catalog = SYSTEM_ROBOT_CATALOG if kind == "system" else PROJECT_ROBOT_CATALOG
            seen = set()
            for item in access:
                if not isinstance(item, dict):
                    return False
                pair = (item.get("resource"), item.get("action"))
                if pair not in catalog or pair in seen:
                    return False
                seen.add(pair)
        if level == "project":
            permission = permissions[0]
            return permission.get("kind") == "project" and permission.get("namespace") != "*"
        return True

    @staticmethod
    def validate_robot_update(body, robot, state):
        duration = body.get("duration")
        level = body.get("level")
        permissions = body.get("permissions")
        if (
            not isinstance(body.get("name"), str)
            or not isinstance(body.get("description"), str)
            or not isinstance(body.get("disable"), bool)
            or not isinstance(duration, int)
            or isinstance(duration, bool)
            or (duration != -1 and not 0 < duration < 2**31 - 1)
            or not HarborHandler.validate_permissions(level, permissions, state)
        ):
            return False
        if level == "project":
            current_permissions = robot.get("permissions", [])
            if not current_permissions:
                return False
            return permissions[0].get("namespace") == current_permissions[0].get(
                "namespace"
            )
        return True

    @staticmethod
    def robot_scope(robot):
        level = robot.get("level")
        if level == "project":
            permissions = robot.get("permissions", [])
            if permissions:
                return "project", permissions[0].get("namespace")
        return "system", "/"

    def dispatch_state(self, path, method):
        state = self.server.store.read()

        if path == "/api/v2.0/configurations" and method in ("GET", "PUT"):
            if not self.is_bootstrap():
                self.finish_status(403, {"errors": [{"code": "FORBIDDEN"}]})
                return
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
        if path == "/api/v2.0/permissions" and method == "GET":
            if not self.is_bootstrap():
                self.finish_status(403, {"errors": [{"code": "FORBIDDEN"}]})
                return
            self.finish_status(
                200,
                {
                    "system": [
                        {"resource": resource, "action": action}
                        for resource, action in sorted(SYSTEM_ROBOT_CATALOG)
                    ],
                    "project": [
                        {"resource": resource, "action": action}
                        for resource, action in sorted(PROJECT_ROBOT_CATALOG)
                    ],
                },
            )
            return
        if path == "/api/v2.0/systeminfo/volumes" and method == "GET":
            if not self.require("system", "/", "system-volumes", "read"):
                return
            self.finish_status(200, state["volumes"])
            return
        if path == "/api/v2.0/projects" and method in ("GET", "POST"):
            if method == "GET":
                if not self.require("system", "/", "project", "list"):
                    return
                self.finish_status(200, state["projects"])
                return
            if not self.require("system", "/", "project", "create"):
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
            metadata = body.get("metadata", {"public": "false"})
            if not self.private_metadata(metadata):
                self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                return
            project_id = state["next_project_id"]
            quota_id = state["next_quota_id"]
            state["next_project_id"] += 1
            state["next_quota_id"] += 1
            project = {"id": project_id, "name": name, "project_id": project_id,
                       "metadata": metadata,
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
                if not self.require("project", project["name"], "project", "update"):
                    return
                body = self.read_json()
                if body is None:
                    return
                if set(body) != {"metadata"} or not self.private_metadata(body["metadata"]):
                    self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                    return
                project["metadata"] = body["metadata"]
                self.server.store.write(state)
                self.finish_status(200)
            else:
                if not self.require("project", project["name"], "project", "read"):
                    return
                self.finish_status(200, project)
            return

        quota_match = re.fullmatch(r"/api/v2\.0/quotas/(\d+)", path)
        if quota_match and method in ("GET", "PUT"):
            quota = self.find(state["quotas"], quota_match.group(1))
            if not quota:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            project = self.find(state["projects"], str(quota["ref"]["id"]))
            if not project:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if method == "PUT":
                if not self.require("system", "/", "quota", "update"):
                    return
                body = self.read_json()
                if body is None:
                    return
                quota.update(body)
                self.server.store.write(state)
                self.finish_status(200)
            else:
                if not self.require("system", "/", "quota", "read"):
                    return
                self.finish_status(200, quota)
            return

        if path == "/api/v2.0/robots" and method in ("GET", "POST"):
            if method == "GET":
                scope = self.robot_list_scope(state)
                if scope is None:
                    self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                    return
                level, project_id, page, page_size = scope
                namespace = "/"
                if level == "project":
                    namespace = self.find(state["projects"], str(project_id))["name"]
                if not self.require(level, namespace, "robot", "list"):
                    return
                visible = []
                for robot in state["robots"]:
                    if robot.get("level") != level:
                        continue
                    if level == "project" and robot.get("project_id") != project_id:
                        continue
                    visible.append(self.public_robot(robot))
                start = (page - 1) * page_size
                self.finish_status(200, visible[start:start + page_size])
                return
            body = self.read_json()
            if body is None:
                return
            if body.get("duration") != -1:
                self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                return
            basename = body.get("name")
            level = body.get("level")
            permissions = body.get("permissions")
            if (
                not isinstance(basename, str)
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", basename)
                or not self.validate_permissions(level, permissions, state)
            ):
                self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                return
            if level == "project":
                namespace = permissions[0]["namespace"]
                if not self.require("project", namespace, "robot", "create"):
                    return
            else:
                namespace = "/"
                if not self.require("system", namespace, "robot", "create"):
                    return
            if self.actor["kind"] == "robot" and not self.permission_subset(
                permissions, self.actor["robot"].get("permissions", [])
            ):
                self.finish_status(403, {"errors": [{"code": "FORBIDDEN"}]})
                return
            stored_name = f"{namespace}+{basename}" if level == "project" else basename
            username = f"{self.robot_prefix(state)}{stored_name}"
            if any(robot.get("name") == username for robot in state["robots"]):
                self.finish_status(409, {"errors": [{"code": "CONFLICT"}]})
                return
            robot_id = state["next_robot_id"]
            state["next_robot_id"] += 1
            secret = generated_robot_secret(robot_id)
            robot = {
                "id": robot_id,
                "name": username,
                "description": body.get("description", ""),
                "disabled": bool(body.get("disabled", body.get("disable", False))),
                "duration": -1,
                "expires_at": -1,
                "creation_time": "2026-08-09T00:00:00Z",
                "level": level,
                "project_id": (
                    self.find(state["projects"], namespace)["project_id"]
                    if level == "project"
                    else 0
                ),
                "permissions": permissions,
                "secret": secret,
            }
            state["robots"].append(robot)
            fault = state.get("fault")
            if (
                isinstance(fault, dict)
                and fault.get("path") == path
                and fault.get("method", method) == method
                and fault.get("mode") == "lost-response"
            ):
                state["fault"] = None
            self.server.store.write(state)
            self.finish_status(
                201,
                {
                    "id": robot_id,
                    "name": username,
                    "secret": secret,
                    "creation_time": "2026-08-09T00:00:00Z",
                    "expires_at": -1,
                },
                {"Location": f"/api/v2.0/robots/{robot_id}"},
            )
            return

        robot_match = re.fullmatch(r"/api/v2\.0/robots/(\d+)", path)
        if robot_match and method in ("GET", "PUT", "PATCH", "DELETE"):
            robot = self.find(state["robots"], robot_match.group(1))
            if not robot:
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if method == "PUT":
                body = self.read_json()
                if body is None:
                    return
                if not self.validate_robot_update(body, robot, state):
                    self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                    return
                kind, namespace = self.robot_scope(robot)
                if not self.require(kind, namespace, "robot", "update"):
                    return
                if body["level"] != robot["level"] or body["name"] != robot["name"]:
                    self.finish_status(400, {"errors": [{"code": "BAD_REQUEST"}]})
                    return
                robot.update(
                    {
                        "description": body["description"],
                        "disabled": body["disable"],
                        "duration": body["duration"],
                        "permissions": body["permissions"],
                    }
                )
                self.server.store.write(state)
                self.finish_status(200)
                return
            if method == "PATCH":
                self.finish_status(403, {"errors": [{"code": "FORBIDDEN"}]})
                return
            kind, namespace = self.robot_scope(robot)
            action = {
                "GET": "read",
                "DELETE": "delete",
            }[method]
            if not self.require(kind, namespace, "robot", action):
                return
            if method == "GET":
                self.finish_status(200, self.public_robot(robot))
            elif method == "DELETE":
                state["robots"].remove(robot)
                self.server.store.write(state)
                self.finish_status(200)
            return

        repositories = re.fullmatch(r"/api/v2\.0/projects/([^/]+)/repositories", path)
        if repositories and method == "GET":
            project = repositories.group(1)
            if not self.find(state["projects"], project):
                self.finish_status(404, {"errors": [{"code": "NOT_FOUND"}]})
                return
            if not self.require("project", project, "repository", "list"):
                return
            names = sorted({key.split("@", 1)[0] for key in state["artifacts"]
                            if key.startswith(project + "/")})
            self.finish_status(200, [{"name": name} for name in names])
            return

        artifact = re.fullmatch(
            r"/api/v2\.0/projects/([^/]+)/repositories/(.+)/artifacts/([^/]+)", path
        )
        if artifact and method == "GET":
            if not self.require("project", artifact.group(1), "artifact", "read"):
                return
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
    endpoint = parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--port", type=int)
    endpoint.add_argument("--unix-socket")
    parser.add_argument("--state", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--credential-file", required=True)
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()
    if args.port is not None and not 0 <= args.port <= 65535:
        parser.error("--port must be between 0 and 65535")

    credential_mode = os.stat(args.credential_file).st_mode & 0o777
    if credential_mode & 0o077:
        parser.error("--credential-file must not be accessible by group or other")
    with open(args.credential_file, encoding="utf-8") as credential_handle:
        credential = json.load(credential_handle)
    username = credential.get("username")
    password = credential.get("password")
    if not isinstance(username, str) or not username or not isinstance(password, str) or not password:
        parser.error("--credential-file must contain non-empty username and password strings")

    with open(args.log, "a", encoding="utf-8", buffering=1) as log_handle:
        if args.unix_socket:
            if os.path.exists(args.unix_socket):
                os.unlink(args.unix_socket)
            server = ThreadingUnixHTTPServer(args.unix_socket, HarborHandler)
        else:
            server = ThreadingHTTPServer(("127.0.0.1", args.port), HarborHandler)
        server.store = StateStore(args.state)
        server.state_lock = threading.Lock()
        server.log_lock = threading.Lock()
        server.log_handle = log_handle
        server.username = username
        server.password = password
        ready_directory = os.path.dirname(os.path.abspath(args.ready_file))
        ready_fd, ready_temporary = tempfile.mkstemp(prefix=".fake-harbor-ready.", dir=ready_directory)
        try:
            with os.fdopen(ready_fd, "w", encoding="utf-8") as ready_handle:
                ready_handle.write(
                    f"{args.unix_socket if args.unix_socket else server.server_address[1]}\n"
                )
            os.replace(ready_temporary, args.ready_file)
        finally:
            if os.path.exists(ready_temporary):
                os.unlink(ready_temporary)
        try:
            server.serve_forever()
        finally:
            server.server_close()
            if args.unix_socket and os.path.exists(args.unix_socket):
                os.unlink(args.unix_socket)


if __name__ == "__main__":
    main()
