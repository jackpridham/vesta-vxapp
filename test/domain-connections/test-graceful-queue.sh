#!/usr/bin/env bash
# Execute the actual scheduled command against isolated service fixtures.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
[[ -x $root/bin/v-apply-vx-graceful-services ]] || { echo 'FAIL: queued adapter is not executable'; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export VESTA=$work
mkdir -p "$work/"{bin,conf,func/vx,data/queue}
python3 - "$root" "$work" <<'PY'
import pathlib, sys
root, work = map(pathlib.Path, sys.argv[1:])
helper = (root/'func/vx/graceful-apply.sh').read_text()
for binary in ('systemctl', 'service', 'nginx', 'apache2ctl'):
    for prefix in ('/usr/bin/', '/usr/sbin/'):
        helper = helper.replace(prefix+binary, str(work/'bin'/binary))
(work/'func/vx/graceful-apply.sh').write_text(helper)
adapter = (root/'bin/v-apply-vx-graceful-services').read_text()
# Run without workstation root. The production privilege check is preserved
# in the source; this fixture substitutes only that kernel identity boundary.
assert '[[ $EUID == 0 ]]' in adapter
adapter = adapter.replace('[[ $EUID == 0 ]]', '[[ 0 == 0 ]]')
adapter = adapter.replace('/usr/bin/python3', str(work/'bin/python3'))
(work/'bin/v-apply-vx-graceful-services').write_text(adapter)
PY
cat >"$work/func/main.sh" <<'STUB'
BIN=$VESTA/bin
E_ARGS=2 E_FORBIDEN=10 E_RESTART=20
check_args() { (( $2 >= $1 )) || exit 2; }
check_result() { [[ $1 == 0 ]] || exit "$1"; }
STUB
cat >"$work/conf/vesta.conf" <<'STUB'
WEB_SYSTEM=apache2
PROXY_SYSTEM=nginx
SCHEDULED_RESTART=yes
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
    'show nginx --property=LimitNOFILESoft --value') printf '256\n' ;;
    'is-active --quiet apache2'|'is-active --quiet nginx') exit 0 ;;
    *) exit 1 ;;
esac
STUB
cat >"$work/bin/service" <<'STUB'
#!/bin/bash
[[ $2 == reload ]] || exit 1
printf '%s %s\n' "$1" "$2" >>"$VESTA/effects"
[[ ! -f $VESTA/reload-failure ]]
STUB
for validator in apache2ctl nginx; do
    printf '#!/bin/bash\nexit 0\n' >"$work/bin/$validator"
done
cat >"$work/bin/python3" <<'STUB'
#!/usr/bin/python3
import builtins, os, sys
source = sys.stdin.read()
sys.argv = sys.argv[1:]
original_open = builtins.open
class AppendDuringAcknowledgement:
    def __init__(self, file): self.file = file
    def __getattr__(self, name): return getattr(self.file, name)
    def __enter__(self): return self
    def __exit__(self, *args): return self.file.__exit__(*args)
    def write(self, value):
        marker = os.environ['VESTA']+'/append-during-ack'
        if os.path.exists(marker):
            with original_open(sys.argv[1], 'ab') as producer:
                producer.write(b'# concurrent unrelated job\n')
            os.unlink(marker)
        return self.file.write(value)
def queue_open(path, mode='r', *args, **kwargs):
    file = original_open(path, mode, *args, **kwargs)
    return AppendDuringAcknowledgement(file) if mode == 'r+b' else file
builtins.open = queue_open
exec(compile(source, '<production acknowledgement>', 'exec'))
STUB
chmod +x "$work/bin/"*
source "$work/func/main.sh"
source "$work/conf/vesta.conf"
source "$work/func/vx/graceful-apply.sh"
queue=$work/data/queue/restart.pipe
printf 'printf "before\\n" >>"$VESTA/neighbors"\n' >"$queue"
vx_graceful_apply '' no apache2 nginx
job=$(tail -n 1 "$queue")
[[ $job == "$BIN/v-apply-vx-graceful-services web proxy now" ]]
printf 'printf "after\\n" >>"$VESTA/neighbors"\n' >>"$queue"
python3 - "$queue" "$work/expected-queue" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_bytes().splitlines(keepends=True)
lines[1] = b' '*(len(lines[1])-1)+b'\n'
pathlib.Path(sys.argv[2]).write_bytes(b''.join(lines))
PY
queue_inode=$(stat -c '%d:%i' "$queue")
bash "$queue"
[[ $(stat -c '%d:%i' "$queue") == "$queue_inode" ]]
cmp "$queue" "$work/expected-queue"
[[ $(cat "$work/effects") == $'apache2 reload\nnginx reload' ]]
[[ $(cat "$work/neighbors") == $'before\nafter' ]]

# A failed apply must leave every byte of the pending queue available to retry.
vx_graceful_apply scheduled no nginx
job=$(tail -n 1 "$queue")
[[ $job == "$BIN/v-apply-vx-graceful-services proxy now" ]]
cp "$queue" "$work/pending-queue"
touch "$work/reload-failure"
if bash -c "$job"; then echo 'FAIL: queued reload failure accepted'; exit 1; fi
cmp "$queue" "$work/pending-queue"
rm "$work/reload-failure"
touch "$work/append-during-ack"
bash -c "$job"
[[ $(stat -c '%d:%i' "$queue") == "$queue_inode" ]]
[[ ! -f $work/append-during-ack ]]
printf '%*s\n# concurrent unrelated job\n' "${#job}" '' >>"$work/expected-queue"
cmp "$queue" "$work/expected-queue"
[[ $(tail -n 2 "$work/effects") == $'nginx reload\nnginx reload' ]]
# An acknowledgement I/O failure must propagate even after the reload succeeds.
rm "$queue"
if bash -c "$job" 2>"$work/acknowledgement-error"; then
    echo 'FAIL: acknowledgement I/O failure accepted'; exit 1
fi
grep -q FileNotFoundError "$work/acknowledgement-error"
printf 'PASS: graceful jobs execute, preserve concurrent appends and retry failures\n'
