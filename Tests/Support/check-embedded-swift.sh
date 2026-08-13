#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates that AxolotyWire compiles AND links under Embedded Swift for
# RISC-V (issues #321, #322).
#
# 1. Compiles AxolotyWire as a separate Swift module (-module-name AxolotyWire)
# 2. Compiles a link probe that `import AxolotyWire` and exercises all
#    runtime-relevant public APIs
# 3. Links the probe against the AxolotyWire module
#
# This catches both compile-time and link-time issues that a compile-only
# check would miss (e.g. missing Unicode runtime symbols, unresolved
# relocations, ABI mismatches).

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wire_dir="$root/Packages/AxolotyWire/Sources/AxolotyWire"
probe="$root/Tests/Support/embedded-swift-link-probe.swift"
parser_probe="$root/Tests/Support/embedded-swift-parser-probe.swift"
host_shims="$root/Tests/Support/embedded-swift-host-shims.c"

if [ ! -d "$wire_dir" ]; then
    echo "FAIL: AxolotyWire source directory not found at $wire_dir" >&2
    exit 1
fi

# Collect all .swift files in the source directory.
swift_files=""
for f in "$wire_dir"/*.swift; do
    if [ -z "$swift_files" ]; then
        swift_files="$f"
    else
        swift_files="$swift_files $f"
    fi
done

if [ -z "$swift_files" ]; then
    echo "FAIL: no .swift files found in $wire_dir" >&2
    exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

jsoncore_dir="$root/.build/checkouts/swift-json/Sources/_JSONCore"
jsoncore_bridge="$root/Embedded/swift/components/json_core/EmbeddedJSONTokenizerResult.swift"
if [ ! -d "$jsoncore_dir" ]; then
    echo "FAIL: pinned swift-json checkout not available at $jsoncore_dir" >&2
    exit 1
fi
jsoncore_files="$jsoncore_dir"/*.swift
jsoncore_files="$jsoncore_files $jsoncore_dir/Parser/*.swift $jsoncore_dir/SIMD/*.swift $jsoncore_bridge"

echo "Compiling _JSONCore as Embedded Swift module..."
if ! swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -package-name IkigaJSON \
    -parse-as-library -Osize -wmo \
    -module-name _JSONCore \
    -emit-module -c $jsoncore_files \
    -o "$workdir/JSONCore.o" \
    -emit-module-path "$workdir/_JSONCore.swiftmodule" 2>&1; then
    echo "FAIL: _JSONCore does not compile under Embedded Swift" >&2
    exit 1
fi

echo "Compiling AxolotyWire as Embedded Swift module..."

# Step 1: Compile AxolotyWire into a .swiftmodule + object file.
if ! swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -parse-as-library \
    -Osize \
    -wmo \
    -module-name AxolotyWire \
    -I "$workdir" \
    -emit-module \
    -c $swift_files \
    -o "$workdir/AxolotyWire.o" \
    -emit-module-path "$workdir/AxolotyWire.swiftmodule" 2>&1; then
    echo "FAIL: AxolotyWire does not compile under Embedded Swift" >&2
    exit 1
fi

module_size=$(wc -c < "$workdir/AxolotyWire.o")
echo "  Module object: ${module_size} bytes"

# Step 2: Compile the link probe that imports AxolotyWire.
echo "Compiling link probe..."
if ! swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -parse-as-library \
    -Osize \
    -wmo \
    -I "$workdir" \
    -c "$probe" \
    -o "$workdir/probe.o" 2>&1; then
    echo "FAIL: link probe does not compile" >&2
    exit 1
fi

probe_size=$(wc -c < "$workdir/probe.o")
echo "  Probe object: ${probe_size} bytes"

# Step 3: Link the probe against the AxolotyWire module.
#
# The host ld/ld.gold cannot handle RISC-V objects (EM: 243). We need
# a cross-platform linker: ld.lld (from LLVM/Swift toolchain) or
# riscv32-esp-elf-ld (from ESP-IDF toolchain).
echo "Linking..."

# Find a linker that can handle RISC-V objects.
RV_LINKER=""
for candidate in \
    /usr/lib/swift/llvm/bin/ld.lld \
    /usr/bin/ld.lld \
    /root/.espressif/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin/ld; do
    if [ -x "$candidate" ]; then
        RV_LINKER="$candidate"
        break
    fi
done

if [ -z "$RV_LINKER" ]; then
    echo "FAIL: no RISC-V-capable linker found (tried ld.lld, riscv32-esp-elf-ld)" >&2
    exit 1
fi

# Partial relocatable link: merges the object files and reports unresolved
# cross-module symbols without requiring a runtime entry point or libc.
if ! "$RV_LINKER" -r \
    -o "$workdir/linked.o" \
    "$workdir/probe.o" \
    "$workdir/AxolotyWire.o" \
    "$workdir/JSONCore.o" 2>"$workdir/link_err.txt"; then
    echo "FAIL: link failed — unresolved symbols or ABI mismatch" >&2
    cat "$workdir/link_err.txt" >&2
    exit 1
fi

linked_size=$(wc -c < "$workdir/linked.o")
echo "EMBEDDED SWIFT OK — compiled and linked: ${module_size} + ${probe_size} = ${linked_size} bytes"

# Compile and execute the parser on the native architecture in Embedded mode.
# This covers the nonthrowing adapter and verifies representative error
# categories; the RISC-V check above still owns target compile/link coverage.
echo "Running Embedded Swift parser behavior probe..."
host_target=$(swiftc -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["target"]["triple"])')
swift_resource_dir=$(swiftc -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')
unicode_archive="$swift_resource_dir/embedded/$host_target/libswiftUnicodeDataTables.a"
if [ ! -f "$unicode_archive" ]; then
    echo "FAIL: Embedded Unicode archive not found for host target $host_target at $unicode_archive" >&2
    exit 1
fi
swiftc \
    -target "$host_target" \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -package-name IkigaJSON \
    -parse-as-library -Osize -wmo \
    -module-name _JSONCore \
    -emit-module -c $jsoncore_files \
    -o "$workdir/JSONCore-host.o" \
    -emit-module-path "$workdir/_JSONCore.swiftmodule"
clang -c "$host_shims" -o "$workdir/embedded-host-shims.o"
swiftc \
    -target "$host_target" \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -Osize -wmo \
    -I "$workdir" \
    $swift_files "$parser_probe" \
    "$workdir/JSONCore-host.o" \
    "$workdir/embedded-host-shims.o" \
    "$unicode_archive" \
    -Xlinker -lm \
    -o "$workdir/embedded-parser-probe"
"$workdir/embedded-parser-probe"
echo "  Parser behavior: valid, missing-data, literal, number, and nesting mappings passed"
