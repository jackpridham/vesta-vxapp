#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
chmod 0700 "$test_root"
export VESTA="$test_root/vesta"
mkdir -p "$VESTA/data/users/alice" "$test_root/input"
chmod 0700 "$test_root/input"
export VX_COMPOSE_PROTECTED_STAGING_ROOTS="$test_root/input"
source "$repo_root/func/vx/compose/common.sh"
VX_COMPOSE_LIB_DIR="$repo_root/func/vx/compose"
source "$repo_root/func/vx/compose/bundles.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$test_root/input" <<'PY'
import gzip, hashlib, io, json, os, tarfile, sys
root=sys.argv[1]
w={"compatibility":{"orchestrator_api":1,"policy_schema":1,"validator_max":1,"validator_min":1},"health_timeout_seconds":120,"image":{"architecture":"amd64","id":"sha256:"+"1"*64,"os":"linux","reference":"local/example:release-1"},"ports":[{"container_port":8080,"host_ip":"127.0.0.1","host_port":8080,"protocol":"tcp","service":"service"}],"probes":{"ready":{"argv":["/usr/local/bin/example-health","--json"],"max_output_bytes":8192,"service":"service","timeout_seconds":15}},"profile":{"name":"admin-approved","version":3},"resources":{"cpus":"1.000","memory_mib":512,"pids":128},"schema":1,"secrets":[],"services":[{"image":"local/example:release-1","name":"service"}],"volumes":[{"name":"state","service":"service","target":"/var/lib/example"}],"workload":{"id":"example","release":"release-1"}}
members={"workload.json":(json.dumps(w,sort_keys=True,separators=(",",":"))+"\n").encode(),"compose.yaml":b'services:\n  service:\n    image: local/example:release-1\n'}
members["manifest.sha256"]=(hashlib.sha256(members["workload.json"]).hexdigest()+"  workload.json\n"+hashlib.sha256(members["compose.yaml"]).hexdigest()+"  compose.yaml\n").encode()
tar=io.BytesIO()
with tarfile.open(fileobj=tar,mode="w",format=tarfile.USTAR_FORMAT) as out:
  for name in sorted(members):
    info=tarfile.TarInfo(name); info.size=len(members[name]); info.mode=0o600; info.uid=info.gid=info.mtime=0; info.uname=info.gname=""
    out.addfile(info,io.BytesIO(members[name]))
# tarfile pads to record size; contract permits only two terminal blocks.
raw=tar.getvalue(); end=raw.rstrip(b"\0"); raw=raw[:((len(end)+511)//512)*512]+b"\0"*1024
with open(root+"/bundle.tar.gz","wb") as out:
  with gzip.GzipFile(fileobj=out,mode="wb",filename="",mtime=0,compresslevel=9) as gz: gz.write(raw)
archive=open(root+"/bundle.tar.gz","rb").read()
archive=archive[:9]+b"\x03"+archive[10:]
open(root+"/bundle.tar.gz","wb").write(archive)
open(root+"/bundle.sha256","w").write(hashlib.sha256(archive).hexdigest()+"  bundle.tar.gz\n")
os.chmod(root+"/bundle.tar.gz",0o600); os.chmod(root+"/bundle.sha256",0o600)
PY

vx_compose_bundle_extract "$test_root/input/bundle.tar.gz" \
    "$test_root/input/bundle.sha256" "$test_root/extracted" \
    || fail 'valid deterministic bundle was rejected'
jq -e '.schema == 1 and .workload.id == "example"' \
    "$test_root/extracted/workload.json" >/dev/null || fail 'workload was not extracted'
[[ "$(stat -c '%a' "$test_root/extracted/workload.json")" == 600 ]] \
    || fail 'extracted workload mode is unsafe'

cp "$test_root/input/bundle.tar.gz" "$test_root/input/tampered.tar.gz"
printf x >>"$test_root/input/tampered.tar.gz"
chmod 0600 "$test_root/input/tampered.tar.gz"
printf '%064d  tampered.tar.gz\n' 0 >"$test_root/input/tampered.sha256"
chmod 0600 "$test_root/input/tampered.sha256"
if vx_compose_bundle_extract "$test_root/input/tampered.tar.gz" \
    "$test_root/input/tampered.sha256" "$test_root/bad" 2>/dev/null; then
    fail 'tampered bundle was accepted'
fi

chmod 0644 "$test_root/input/bundle.tar.gz"
if vx_compose_bundle_extract "$test_root/input/bundle.tar.gz" \
    "$test_root/input/bundle.sha256" "$test_root/insecure" 2>/dev/null; then
    fail 'insecure archive was accepted'
fi

echo 'Compose workload bundle tests passed.'
