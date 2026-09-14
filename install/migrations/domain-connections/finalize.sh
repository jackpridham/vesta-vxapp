#!/bin/bash
# info: finalize a revision-bound native domain adoption
# options: USER NATIVE_PRIMARY [REVISION]
exec bash "$(dirname -- "$0")/run.sh" finalize "$@"
