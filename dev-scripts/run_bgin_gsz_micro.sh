#!/usr/bin/env bash

# Run from the Linux repository root. Compiles each microbenchmark once,
# then runs GSZ and BGI-N on LAN/WAN with 3, 5, 7, 9, 11, 13, 15 parties.
# Replaces ./bgin-gsz-micro-result.txt.
set -u
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
exec bash "$SCRIPT_DIR/run_bgin_gsz.sh" micro
