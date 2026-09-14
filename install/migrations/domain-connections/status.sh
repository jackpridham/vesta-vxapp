#!/bin/bash
# info: inspect protected native domain migration state without changes
# options: USER NATIVE_PRIMARY
exec bash "$(dirname -- "$0")/run.sh" status "$@"
