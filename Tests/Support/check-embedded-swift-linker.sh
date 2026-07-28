#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Regression check for the Embedded Swift UnicodeDataTables/.got.plt linker
# integration. Runs inside the development container; no device is required.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
project="$root/Embedded/swift"
build_dir=/workspace/.build/embedded-swift-linker-probe

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
cd "$project"

rm -rf "$build_dir"
idf.py -B "$build_dir" -DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON set-target esp32c6 >/dev/null
idf.py -B "$build_dir" -DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON build >/dev/null

elf="$build_dir/axoloty-swift.elf"
map="$build_dir/axoloty-swift.map"
sections="$build_dir/esp-idf/esp_system/ld/sections.ld"

test -f "$elf"
test -f "$map"
test -f "$sections"

nm_tool=${RISCV_NM:-riscv32-esp-elf-nm}
"$nm_tool" "$elf" | grep -q ' [TDR] _swift_stdlib_getNormData$'
"$nm_tool" "$elf" | grep -q ' [TDR] axoloty_unicode_linker_probe$'
grep -q 'libswiftUnicodeDataTables.a' "$map"
grep -q '\*(\.got \.got\.\* \.got\.plt \.got\.plt\.\*)' "$sections"
grep -q 'Swift UnicodeDataTables requires \.got/\.got\.plt' "$sections"
if grep -Eiq 'discarded output section.*\.got|orphan.*\.got' "$build_dir/log/"* 2>/dev/null; then
    echo "EMBEDDED SWIFT LINKER FAIL: GOT/PLT was discarded or orphaned" >&2
    exit 1
fi

echo "EMBEDDED SWIFT LINKER OK"
