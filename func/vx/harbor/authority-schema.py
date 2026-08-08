#!/usr/bin/env python3
import datetime, json, pathlib, re, sys

OWNER = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
NAMESPACE = re.compile(r"[a-z0-9][a-z0-9-]{0,127}")
OPERATION = re.compile(r"[a-f0-9]{32}")
SHA = re.compile(r"[a-f0-9]{64}")
PACKAGE = re.compile(r"[A-Za-z0-9._-]+")
USERNAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+$-]{0,127}")

def fail(): raise ValueError()
def exact(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys) or value.get("SCHEMA") != 1: fail()
def integer(value, minimum=0, maximum=2**63-1):
    return isinstance(value, int) and not isinstance(value, bool) and minimum <= value <= maximum
def timestamp(value):
    if not isinstance(value, str) or len(value) != 20: fail()
    try: datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError: fail()
def nullable_robot(value):
    if value is not None and not integer(value, 1): fail()
def nullable_text(value, maximum=160):
    if value is not None and (not isinstance(value, str) or not 1 <= len(value) <= maximum): fail()

def validate(kind, value, identity):
    if kind == "package-operation":
        exact(value, ("SCHEMA","OPERATION_ID","OWNER","DESIRED_PACKAGE","DESIRED_REGISTRY_MB","STATE","ATTEMPTS","LAST_ERROR","CREATED_AT","UPDATED_AT"))
        if not OPERATION.fullmatch(value["OPERATION_ID"]) or not OWNER.fullmatch(value["OWNER"]) or value["OWNER"] != identity: fail()
        if not isinstance(value["DESIRED_PACKAGE"],str) or not PACKAGE.fullmatch(value["DESIRED_PACKAGE"]): fail()
        if not isinstance(value["DESIRED_REGISTRY_MB"],str) or not re.fullmatch(r"0|[1-9][0-9]*|unlimited",value["DESIRED_REGISTRY_MB"]): fail()
        if value["STATE"] not in {"pending","converged","failed"} or not integer(value["ATTEMPTS"],0,3): fail()
        nullable_text(value["LAST_ERROR"])
        if not integer(value["CREATED_AT"]) or not integer(value["UPDATED_AT"],value["CREATED_AT"]): fail()
        if value["STATE"] == "pending" and value["LAST_ERROR"] is not None: fail()
    elif kind == "rotation":
        exact(value,("SCHEMA","OPERATION_ID","OWNER","KIND","PHASE","NEW_ROBOT_ID","NEW_USERNAME","OLD_ROBOT_ID","UPDATED_AT"))
        owner, journal_kind = identity.split(":",1)
        if value["OWNER"] != owner or value["KIND"] != journal_kind or not OWNER.fullmatch(owner): fail()
        if journal_kind not in {"runtime","publisher"} or not OPERATION.fullmatch(value["OPERATION_ID"]): fail()
        if value["PHASE"] not in {"pending-switch","pending-revoke","converged"}: fail()
        nullable_robot(value["NEW_ROBOT_ID"]); nullable_robot(value["OLD_ROBOT_ID"])
        if value["NEW_ROBOT_ID"] is None or not isinstance(value["NEW_USERNAME"],str) or not USERNAME.fullmatch(value["NEW_USERNAME"]): fail()
        if value["OLD_ROBOT_ID"] == value["NEW_ROBOT_ID"]: fail()
        timestamp(value["UPDATED_AT"])
    elif kind == "tombstone":
        exact(value,("SCHEMA","OPERATION_ID","OWNER","NAMESPACE","PUBLISHER_ROBOT_ID","RUNTIME_ROBOT_ID","PHASE","UPDATED_AT"))
        if value["OWNER"] != identity or not OWNER.fullmatch(value["OWNER"]) or not NAMESPACE.fullmatch(value["NAMESPACE"]): fail()
        if not OPERATION.fullmatch(value["OPERATION_ID"]) or value["PHASE"] not in {"publisher","runtime"}: fail()
        nullable_robot(value["PUBLISHER_ROBOT_ID"]); nullable_robot(value["RUNTIME_ROBOT_ID"]); timestamp(value["UPDATED_AT"])
    elif kind == "owner":
        exact(value,("SCHEMA","OWNER","NAMESPACE","PROJECT_ID","QUOTA_ID","QUOTA_MB","STATE","RUNTIME_ROBOT_ID","RUNTIME_USERNAME","PUBLISHER_ROBOT_ID","PUBLISHER_USERNAME","PUBLISHER_ENABLED","LAST_ERROR","UPDATED_AT"))
        if value["OWNER"] != identity or not OWNER.fullmatch(value["OWNER"]) or not NAMESPACE.fullmatch(value["NAMESPACE"]): fail()
        if not integer(value["PROJECT_ID"],1) or not integer(value["QUOTA_ID"],1): fail()
        if value["QUOTA_MB"] != "unlimited" and not integer(value["QUOTA_MB"]): fail()
        if value["STATE"] not in {"project-ready","runtime-ready","publisher-ready","publisher-disabled","retained","unavailable"}: fail()
        nullable_robot(value["RUNTIME_ROBOT_ID"]); nullable_robot(value["PUBLISHER_ROBOT_ID"])
        for rid,user in ((value["RUNTIME_ROBOT_ID"],value["RUNTIME_USERNAME"]),(value["PUBLISHER_ROBOT_ID"],value["PUBLISHER_USERNAME"])):
            if (rid is None) != (user is None): fail()
            if user is not None and (not isinstance(user,str) or not USERNAME.fullmatch(user)): fail()
        if not isinstance(value["PUBLISHER_ENABLED"],bool) or value["PUBLISHER_ENABLED"] != (value["PUBLISHER_ROBOT_ID"] is not None): fail()
        nullable_text(value["LAST_ERROR"]); timestamp(value["UPDATED_AT"])
    elif kind == "backup":
        exact(value,("SCHEMA","BACKUP_ID","CIPHERTEXT","SHA256","CREATED_AT","VERSION"))
        if not isinstance(value["BACKUP_ID"],str) or not re.fullmatch(r"harbor-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}",value["BACKUP_ID"]): fail()
        if value["BACKUP_ID"] != identity or value["CIPHERTEXT"] != identity+".tar.age" or value["VERSION"] != "v2.15.0" or not SHA.fullmatch(value["SHA256"]): fail()
        timestamp(value["CREATED_AT"])
    elif kind == "observation-owner":
        exact(value,("SCHEMA","GENERATION","OBSERVED_AT","USED_MB"))
        if not SHA.fullmatch(value["GENERATION"]) or not integer(value["USED_MB"]): fail()
        timestamp(value["OBSERVED_AT"])
    elif kind == "observation-provider":
        exact(value,("SCHEMA","HEALTH","OBSERVED_AT"))
        if value["HEALTH"] not in {"healthy","degraded","unavailable"}: fail()
        timestamp(value["OBSERVED_AT"])
    elif kind == "observation-detail":
        exact(value,("SCHEMA","OBSERVED_AT","HEALTH","CERTIFICATE","STORAGE","OPERATIONS","OWNERS"))
        if value["HEALTH"] not in {"healthy","degraded","unavailable"} or not isinstance(value["CERTIFICATE"],dict) or set(value["STORAGE"])!={"USED_BYTES","TOTAL_BYTES"} or set(value["OPERATIONS"])!={"PENDING","FAILED"} or not isinstance(value["OWNERS"],list): fail()
        timestamp(value["OBSERVED_AT"])
        if not all(integer(value["STORAGE"][x]) for x in value["STORAGE"]) or not all(integer(value["OPERATIONS"][x]) for x in value["OPERATIONS"]): fail()
    elif kind == "disable-plan":
        exact(value,("SCHEMA","TOKEN","CREATED_AT","EXPIRES_AT","MODE","OPERATIONS","BLOCKERS","AFFECTED_OWNERS","RETAINED_DATA"))
        if not isinstance(value["TOKEN"],str) or not OPERATION.fullmatch(value["TOKEN"]) or value["MODE"]!="managed": fail()
        if not integer(value["CREATED_AT"]) or not integer(value["EXPIRES_AT"],value["CREATED_AT"]): fail()
        if value["RETAINED_DATA"] != ["provider database","OCI artifacts","owner mappings","encrypted backups"]: fail()
        for item in value["OPERATIONS"]:
            if not isinstance(item,dict) or set(item)!={"FILE","OWNER","OPERATION_ID","STATE","UPDATED_AT"}: fail()
            if item["FILE"] != item["OWNER"]+".json" or not OWNER.fullmatch(item["OWNER"]) or not OPERATION.fullmatch(item["OPERATION_ID"]) or item["STATE"] not in {"pending","converged","failed"} or not integer(item["UPDATED_AT"]): fail()
        for item in value["BLOCKERS"]:
            if not isinstance(item,dict) or set(item)!={"OWNER","OPERATION_ID","STATE"} or item["STATE"] not in {"pending","failed"} or not OWNER.fullmatch(item["OWNER"]) or not OPERATION.fullmatch(item["OPERATION_ID"]): fail()
        for item in value["AFFECTED_OWNERS"]:
            if not isinstance(item,dict) or set(item)!={"OWNER","NAMESPACE","STATE"} or not OWNER.fullmatch(item["OWNER"]) or not NAMESPACE.fullmatch(item["NAMESPACE"]) or item["STATE"] not in {"project-ready","runtime-ready","publisher-ready","publisher-disabled","retained","unavailable"}: fail()
        expected=[{"OWNER":x["OWNER"],"OPERATION_ID":x["OPERATION_ID"],"STATE":x["STATE"]} for x in value["OPERATIONS"] if x["STATE"] in {"pending","failed"}]
        if value["BLOCKERS"] != expected: fail()
    else: fail()

try:
    kind,path,identity=sys.argv[1:4]
    value=json.loads(pathlib.Path(path).read_text())
    validate(kind,value,identity)
except (ValueError, KeyError, TypeError, json.JSONDecodeError, OSError):
    raise SystemExit(1)
