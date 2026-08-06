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
w["compatibility"]["validator_max"]=2
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

python3 - "$test_root/input" <<'PY'
import gzip,hashlib,io,os,tarfile,sys
root=sys.argv[1]
base=gzip.decompress(open(root+"/bundle.tar.gz","rb").read())
members={}
with tarfile.open(fileobj=io.BytesIO(base),mode="r:") as source:
  for item in source: members[item.name]=source.extractfile(item).read()
def write(name, entries, link=None):
  stream=io.BytesIO()
  with tarfile.open(fileobj=stream,mode="w",format=tarfile.USTAR_FORMAT) as out:
    for member,data in entries:
      info=tarfile.TarInfo(member); info.mode=0o600;info.uid=info.gid=info.mtime=0;info.uname=info.gname=""
      if link and member==link: info.type=tarfile.SYMTYPE;info.linkname="compose.yaml";info.size=0;out.addfile(info)
      else: info.size=len(data);out.addfile(info,io.BytesIO(data))
  raw=stream.getvalue();end=raw.rstrip(b"\0");raw=raw[:((len(end)+511)//512)*512]+b"\0"*1024
  buf=io.BytesIO()
  with gzip.GzipFile(fileobj=buf,mode="wb",filename="",mtime=0,compresslevel=9) as zipped:zipped.write(raw)
  archive=buf.getvalue();archive=archive[:9]+b"\x03"+archive[10:]
  open(root+f"/{name}.tar.gz","wb").write(archive)
  open(root+f"/{name}.sha256","w").write(hashlib.sha256(archive).hexdigest()+f"  {name}.tar.gz\n")
  os.chmod(root+f"/{name}.tar.gz",0o600);os.chmod(root+f"/{name}.sha256",0o600)
ordered=[(key,members[key]) for key in sorted(members)]
write("extra",ordered+[("unexpected",b"x")])
write("traversal",[("../compose.yaml",members["compose.yaml"]),ordered[1],ordered[2]])
write("link",ordered,link="compose.yaml")
bad=members["workload.json"].replace(b'"schema":1',b'"schema":1,"schema":1',1)
bad_manifest=(hashlib.sha256(bad).hexdigest()+"  workload.json\n"+hashlib.sha256(members["compose.yaml"]).hexdigest()+"  compose.yaml\n").encode()
bad_entries=[(key,bad if key=="workload.json" else bad_manifest if key=="manifest.sha256" else value) for key,value in ordered]
write("duplicate-json",bad_entries)
PY

vx_compose_bundle_extract "$test_root/input/bundle.tar.gz" \
    "$test_root/input/bundle.sha256" "$test_root/extracted" \
    || fail 'valid deterministic bundle was rejected'
jq -e '.schema == 1 and .workload.id == "example"' \
    "$test_root/extracted/workload.json" >/dev/null || fail 'workload was not extracted'
[[ "$(stat -c '%a' "$test_root/extracted/workload.json")" == 600 ]] \
    || fail 'extracted workload mode is unsafe'
vx_compose_bundle_compatibility_validate \
    "$test_root/extracted/workload.json" \
    || fail 'installed validator compatibility was rejected'
jq '.compatibility.validator_max=1' "$test_root/extracted/workload.json" \
    >"$test_root/incompatible.json"
if vx_compose_bundle_compatibility_validate \
    "$test_root/incompatible.json" 2>/dev/null; then
    fail 'unsupported installed validator version was accepted'
fi

vx_compose_profile_version() { printf '3\n'; }
cat >"$test_root/policy.conf" <<'EOF'
MEMORY_MB='512'
PIDS='128'
CPUS_MILLI='1000'
EOF
jq -nS '{services:{service:{image:"local/example:release-1",
  ports:[{host_ip:"127.0.0.1",published:"8080",target:8080,protocol:"tcp"}],
  volumes:[{type:"volume",source:"state",target:"/var/lib/example"}]}},
  volumes:{state:{}}}' >"$test_root/canonical.json"
vx_compose_bundle_manifest_check_compose \
    "$test_root/extracted/workload.json" "$test_root/canonical.json" \
    "$test_root/policy.conf" admin-approved \
    || fail 'exact workload mounts were rejected'
jq '.services.service.volumes += [{type:"volume",source:"state",target:"/extra"}]' \
    "$test_root/canonical.json" >"$test_root/extra-mount.json"
if vx_compose_bundle_manifest_check_compose \
    "$test_root/extracted/workload.json" "$test_root/extra-mount.json" \
    "$test_root/policy.conf" admin-approved 2>/dev/null; then
    fail 'extra service-level mount was accepted'
fi

authority="$test_root/authority"
mkdir -m 0700 "$authority"
install -m 0600 "$test_root/extracted/workload.json" "$authority/workload.json"
install -m 0600 "$test_root/extracted/manifest.sha256" \
    "$authority/workload-manifest.sha256"
install -m 0600 "$test_root/policy.conf" "$authority/policy.conf"
jq --arg id "sha256:$(printf '1%.0s' {1..64})" \
    '.services.service.image=$id' "$test_root/canonical.json" \
    >"$authority/canonical.json"
chmod 0600 "$authority/canonical.json"
workload_sha="$(sha256sum "$authority/workload.json" | awk '{print $1}')"
compose_sha="$(awk '$2=="compose.yaml"{print $1}' \
    "$authority/workload-manifest.sha256")"
manifest_sha="$(sha256sum "$authority/workload-manifest.sha256" | awk '{print $1}')"
canonical_sha="$(sha256sum "$authority/canonical.json" | awk '{print $1}')"
jq -nS --arg archive "$(printf '2%.0s' {1..64})" \
    --arg canonical "$canonical_sha" --arg compose "$compose_sha" \
    --arg manifest "$manifest_sha" --arg workload "$workload_sha" \
    '{ARCHIVE_SHA256:$archive,CANONICAL_SHA256:$canonical,
      COMPOSE_SHA256:$compose,MANIFEST_SHA256:$manifest,
      WORKLOAD_SHA256:$workload}' >"$authority/workload-evidence.json"
chmod 0600 "$authority/workload-evidence.json"
vx_compose_image_approval_require() { return 0; }
vx_compose_workload_authority_validate alice "$authority" \
    || fail 'complete workload authority was rejected'
cp "$authority/workload-evidence.json" "$authority/evidence.saved"
jq '.WORKLOAD_SHA256=("0" * 64)' "$authority/evidence.saved" \
    >"$authority/workload-evidence.json"
chmod 0600 "$authority/workload-evidence.json"
if vx_compose_workload_authority_validate alice "$authority" 2>/dev/null; then
    fail 'corrupt restored workload authority was accepted'
fi
mv "$authority/evidence.saved" "$authority/workload-evidence.json"
chmod 0600 "$authority/workload-evidence.json"
printf '\n' >>"$authority/workload-manifest.sha256"
manifest_sha="$(sha256sum "$authority/workload-manifest.sha256" | awk '{print $1}')"
jq --arg manifest "$manifest_sha" '.MANIFEST_SHA256=$manifest' \
    "$authority/workload-evidence.json" >"$authority/.evidence" \
    && mv "$authority/.evidence" "$authority/workload-evidence.json"
chmod 0600 "$authority/workload-evidence.json"
if vx_compose_workload_authority_validate alice "$authority" 2>/dev/null; then
    fail 'workload manifest with an extra trailing newline was accepted'
fi

fake_docker="$test_root/fake-docker"
cat >"$fake_docker" <<'EOF'
#!/usr/bin/env bash
base="$(dirname -- "$0")"
if [[ -f "$base/zero-secret" ]]; then
  printf '%s\n' '{"services":{"service":{"image":"local/example:release-1"}}}'
elif [[ -f "$base/extra-secret" ]]; then
  printf '%s\n' '{"services":{"service":{"image":"local/example:release-1","secrets":[{"source":"credential","target":"/run/secrets/credential"}]}},"secrets":{"credential":{"external":true},"undeclared":{"external":true}}}'
else
  printf '%s\n' '{"services":{"service":{"image":"local/example:release-1","secrets":[{"source":"credential","target":"/run/secrets/credential"}]}},"secrets":{"credential":{"external":true}}}'
fi
EOF
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"
vx_compose_project_root() { printf '%s/data/users/%s/docker-projects/%s\n' "$VESTA" "$1" "$2"; }
touch "$test_root/zero-secret"
vx_compose_bundle_secret_definition_rewrite alice app \
    "$test_root/extracted/compose.yaml" "$test_root/extracted/workload.json" \
    "$test_root/zero-managed-compose.json" \
    || fail 'zero-secret workload rewrite was rejected'
jq -e '.secrets=={}' "$test_root/zero-managed-compose.json" >/dev/null \
    || fail 'zero-secret workload was not normalized exactly'
rm -f -- "$test_root/zero-secret"
jq '.secrets=[{"name":"credential","target":"/run/secrets/credential"}]' \
    "$test_root/extracted/workload.json" >"$test_root/secret-workload.json"
vx_compose_bundle_secret_definition_rewrite alice app \
    "$test_root/extracted/compose.yaml" "$test_root/secret-workload.json" \
    "$test_root/managed-compose.json" \
    || fail 'abstract secret was not rewritten to managed authority'
jq -e --arg path "$VESTA/data/users/alice/docker-projects/app/runtime/workload-secrets/current/credential" \
    '.secrets=={credential:{file:$path}}' "$test_root/managed-compose.json" \
    >/dev/null || fail 'managed secret rewrite was not exact'
touch "$test_root/extra-secret"
if vx_compose_bundle_secret_definition_rewrite alice app \
    "$test_root/extracted/compose.yaml" "$test_root/secret-workload.json" \
    "$test_root/extra-managed-compose.json" 2>/dev/null; then
    fail 'undeclared external secret was accepted'
fi

mkdir -m 0700 "$test_root/input/secret-input"
printf '{"secrets":[{"name":"credential"}]}\n' >"$test_root/secret-manifest.json"
printf 'value\n' >"$test_root/input/secret-input/credential"
chmod 0600 "$test_root/input/secret-input/credential"
/usr/bin/python3 "$repo_root/func/vx/compose/bundle-secrets.py" \
    "$test_root/secret-manifest.json" "$test_root/input/secret-input" \
    "$test_root/secret-snapshot" || fail 'protected secret snapshot failed'
cmp -s "$test_root/input/secret-input/credential" \
    "$test_root/secret-snapshot/credential" || fail 'secret snapshot changed bytes'
find "$test_root/secret-snapshot" -depth -delete
find "$test_root/input/secret-input" -depth -delete
mkdir -m 0700 "$test_root/input/secret-input"
ln -s /dev/null "$test_root/input/secret-input/credential"
if /usr/bin/python3 "$repo_root/func/vx/compose/bundle-secrets.py" \
    "$test_root/secret-manifest.json" "$test_root/input/secret-input" \
    "$test_root/linked-secret" 2>/dev/null; then
    fail 'linked secret input was accepted'
fi
find "$test_root/input/secret-input" -depth -delete
mkdir -m 0700 "$test_root/input/secret-input"
printf 'value\n' >"$test_root/input/secret-input/first"
ln "$test_root/input/secret-input/first" \
    "$test_root/input/secret-input/second"
chmod 0600 "$test_root/input/secret-input/first"
printf '{"secrets":[{"name":"first"},{"name":"second"}]}\n' \
    >"$test_root/hardlink-manifest.json"
if /usr/bin/python3 "$repo_root/func/vx/compose/bundle-secrets.py" \
    "$test_root/hardlink-manifest.json" "$test_root/input/secret-input" \
    "$test_root/hardlink-secret" 2>/dev/null; then
    fail 'hard-linked secret inputs were accepted'
fi
find "$test_root/input/secret-input" -depth -delete
mkdir -m 0700 "$test_root/input/secret-input"
printf 'before\n' >"$test_root/input/secret-input/credential"
chmod 0600 "$test_root/input/secret-input/credential"
if (( EUID != 0 )); then
    VX_COMPOSE_BUNDLE_SECRET_TEST_PAUSE=yes /usr/bin/python3 \
        "$repo_root/func/vx/compose/bundle-secrets.py" \
        "$test_root/secret-manifest.json" "$test_root/input/secret-input" \
        "$test_root/raced-secret" 2>/dev/null &
    snapshot_pid=$!
    for _ in {1..100}; do
        [[ -e "$test_root/raced-secret/credential" ]] && break
        sleep 0.01
    done
    printf 'after!\n' >"$test_root/input/secret-input/credential"
    if wait "$snapshot_pid"; then
        fail 'mutating secret input was accepted'
    fi
    find "$test_root/raced-secret" -depth -delete 2>/dev/null || :
    printf 'stable\n' >"$test_root/input/secret-input/credential"
    for swap_kind in parent directory; do
        VX_COMPOSE_BUNDLE_SECRET_TEST_PAUSE="$swap_kind" /usr/bin/python3 \
            "$repo_root/func/vx/compose/bundle-secrets.py" \
            "$test_root/secret-manifest.json" \
            "$test_root/input/secret-input" \
            "$test_root/$swap_kind-swap-secret" >/dev/null 2>&1 &
        snapshot_pid=$!
        for _ in {1..100}; do
            [[ -e "$test_root/.bundle-secrets-test-ready" ]] && break
            sleep 0.01
        done
        [[ -e "$test_root/.bundle-secrets-test-ready" ]] \
            || fail "$swap_kind swap did not reach descriptor snapshot"
        if [[ "$swap_kind" == parent ]]; then
            mv "$test_root/input" "$test_root/input-held"
            mkdir -m 0700 "$test_root/input"
        else
            mv "$test_root/input/secret-input" \
                "$test_root/input/secret-input-held"
            mkdir -m 0700 "$test_root/input/secret-input"
            printf 'replacement\n' \
                >"$test_root/input/secret-input/credential"
            chmod 0600 "$test_root/input/secret-input/credential"
        fi
        if wait "$snapshot_pid"; then
            fail "$swap_kind secret staging replacement was accepted"
        fi
        if [[ "$swap_kind" == parent ]]; then
            rmdir "$test_root/input"
            mv "$test_root/input-held" "$test_root/input"
        else
            find "$test_root/input/secret-input" -depth -delete
            mv "$test_root/input/secret-input-held" \
                "$test_root/input/secret-input"
        fi
        find "$test_root/$swap_kind-swap-secret" -depth -delete \
            2>/dev/null || :
    done
fi

cp "$test_root/input/bundle.tar.gz" "$test_root/input/tampered.tar.gz"
printf x >>"$test_root/input/tampered.tar.gz"
chmod 0600 "$test_root/input/tampered.tar.gz"
printf '%064d  tampered.tar.gz\n' 0 >"$test_root/input/tampered.sha256"
chmod 0600 "$test_root/input/tampered.sha256"
if vx_compose_bundle_extract "$test_root/input/tampered.tar.gz" \
    "$test_root/input/tampered.sha256" "$test_root/bad" 2>/dev/null; then
    fail 'tampered bundle was accepted'
fi
for malformed in extra traversal link duplicate-json; do
    if vx_compose_bundle_extract "$test_root/input/$malformed.tar.gz" \
        "$test_root/input/$malformed.sha256" "$test_root/$malformed" 2>/dev/null; then
        fail "malformed $malformed bundle was accepted"
    fi
done

if (( EUID != 0 )); then
    VX_COMPOSE_BUNDLE_VALIDATOR_TEST_PAUSE=yes /usr/bin/python3 \
        "$repo_root/func/vx/compose/bundle-validator.py" \
        "$test_root/input/bundle.tar.gz" "$test_root/input/bundle.sha256" \
        "$test_root/swapped-output" >/dev/null 2>"$test_root/swap-error" &
    validator_pid=$!
    for _ in {1..100}; do
        [[ -e "$test_root/.bundle-validator-test-ready" ]] && break
        sleep 0.01
    done
    [[ -e "$test_root/.bundle-validator-test-ready" ]] \
        || fail 'validator parent-swap test did not reach descriptor snapshot'
    mv "$test_root/input" "$test_root/input-held"
    mkdir -m 0700 "$test_root/input"
    if wait "$validator_pid"; then
        fail 'validator accepted a replaced input parent directory'
    fi
    [[ ! -e "$test_root/swapped-output" \
        && "$(<"$test_root/swap-error")" == 'workload bundle rejected' ]] \
        || fail 'parent replacement leaked output or internal details'
    rmdir "$test_root/input"
    mv "$test_root/input-held" "$test_root/input"
fi

chmod 0644 "$test_root/input/bundle.tar.gz"
if vx_compose_bundle_extract "$test_root/input/bundle.tar.gz" \
    "$test_root/input/bundle.sha256" "$test_root/insecure" 2>/dev/null; then
    fail 'insecure archive was accepted'
fi

validator_error="$(/usr/bin/python3 \
    "$repo_root/func/vx/compose/bundle-validator.py" \
    "$test_root/input/private-missing.tar.gz" \
    "$test_root/input/private-missing.sha256" \
    "$test_root/private-output" 2>&1 || :)"
[[ "$validator_error" == 'workload bundle rejected' \
    && "$validator_error" != *private-missing* \
    && "$validator_error" != *Traceback* ]] \
    || fail 'validator disclosed an internal path or exception detail'

(
    import_root="$test_root/import-project"
    vx_compose_project_root() { printf '%s\n' "$import_root"; }
    vx_compose_lock_acquire() { :; }
    vx_compose_lock_release() { :; }
    vx_compose_bundle_extract() {
        mkdir -m 0700 "$3"
        install -m 0600 "$test_root/extracted/workload.json" \
            "$3/workload.json"
    }
    vx_compose_bundle_candidate_prepare() { mkdir -m 0700 "$4"; }
    vx_compose_store_new() {
        mkdir -m 0750 "$import_root"
        printf "REVISION='1'\nPROFILE='admin-approved'\n" \
            >"$import_root/project.conf"
    }
    vx_compose_deploy() { :; }
    vx_compose_meta_get() {
        case "$2" in
            REVISION) printf '1\n' ;;
            PROFILE) printf 'admin-approved\n' ;;
            *) return 1 ;;
        esac
    }
    vx_compose_transaction_update() {
        printf '%s\n' called >"$test_root/change-import-called"
    }
    vx_compose_bundle_import admin alice app \
        "$test_root/input/bundle.tar.gz" "$test_root/input/bundle.sha256" \
        add 0 '' || fail 'zero-secret add import was rejected'
    vx_compose_bundle_import admin alice app \
        "$test_root/input/bundle.tar.gz" "$test_root/input/bundle.sha256" \
        change 1 '' || fail 'zero-secret change import was rejected'
)
[[ -s "$test_root/change-import-called" ]] \
    || fail 'zero-secret change import did not reach its transaction'

lock_marker="$test_root/invalid-import.locked"
vx_compose_lock_acquire() { touch "$lock_marker"; return 1; }
if vx_compose_bundle_import admin alice 'bad/project' \
    "$test_root/input/bundle.tar.gz" "$test_root/input/bundle.sha256" \
    add 0 2>/dev/null; then
    fail 'invalid import target was accepted'
fi
[[ ! -e "$lock_marker" ]] \
    || fail 'invalid import target reached lock/path derivation'

echo 'Compose workload bundle tests passed.'
