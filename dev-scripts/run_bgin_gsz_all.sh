#!/usr/bin/env bash

# Run from the Linux repository root. Runs all NNs followed by all four
# microbenchmarks, completing each program's runs before compiling the next.
# Replaces ./bgin-gsz-all-result.txt (224 experiments, eight compilations).
set -u
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
exec bash "$SCRIPT_DIR/run_bgin_gsz.sh" all
