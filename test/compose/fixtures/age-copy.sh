#!/usr/bin/env bash
set -Eeuo pipefail

output=
input=
while (($#)); do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        --recipient|--identity)
            shift 2
            ;;
        --encrypt|--decrypt)
            shift
            ;;
        *)
            input=$1
            shift
            ;;
    esac
done
cp -- "$input" "$output"
