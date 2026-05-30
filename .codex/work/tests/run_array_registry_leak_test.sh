#!/usr/bin/env bash
# Build and run the native array registry leak regression test.
# Proves kira_array_alloc() performs exactly one raw allocation per array
# (the KiraArray struct) with the registry removed, and that array behavior
# (alloc/len/store/load/append/release + null/oob contract) is preserved.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/../../../packages/kira_native_bridge/src/runtime_helpers.c"
out="$here/leak_test"
trap 'rm -f "$out"' EXIT
cc -O2 -Wall "$here/array_registry_leak_test.c" "$helper" -o "$out"
"$out"
