#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Compile AxolotyZenohCore and its AxolotyWire dependency as Embedded Swift for
# RISC-V and partially link them. The gate needs no zenoh-c archive, router,
# firmware project, SDK, or hardware: AxolotyZenohCore reaches Zenoh only
# through the self-contained C façade header, whose symbols the firmware
# façade build supplies later.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

for tool in swift swiftc node nm; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FAIL: $tool is required for the Embedded Swift Zenoh core check" >&2
        exit 1
    }
done

zenoh_package="$root_dir/Packages/AxolotyZenoh"
facade_header="$zenoh_package/Sources/CAxolotyZenoh/include/axoloty_zenoh.h"
zenoh_core_dir="$zenoh_package/Sources/AxolotyZenohCore"
wire_dir="$root_dir/Packages/AxolotyWire/Sources/AxolotyWire"
for required in "$facade_header" "$zenoh_core_dir" "$wire_dir"; do
    [ -e "$required" ] || {
        echo "FAIL: Embedded Swift Zenoh core input is missing: $required" >&2
        exit 1
    }
done

# Compiler and SwiftPM checkout state stays in a caller-owned temporary tree
# outside the source checkout.
scratch_parent=${AXOLOTY_EMBEDDED_ZENOH_CHECK_DIR:-/tmp/axoloty-embedded-zenoh-core}
case "$scratch_parent" in
    /*) ;;
    *)
        echo "FAIL: AXOLOTY_EMBEDDED_ZENOH_CHECK_DIR must be absolute: $scratch_parent" >&2
        exit 1
        ;;
esac
mkdir -p -- "$scratch_parent"
workdir=$(mktemp -d "$scratch_parent/run.XXXXXX")
trap 'rm -rf -- "$workdir"' EXIT HUP INT TERM

# _JSONCore comes from the Zenoh package's own lock, which must agree with the
# revision the embedded consumer contract pins.
echo "Resolving the locked AxolotyZenoh dependencies..."
swift package resolve \
    --package-path "$zenoh_package" \
    --scratch-path "$workdir/swiftpm" \
    --cache-path "$root_dir/.swiftpm-cache" \
    --disable-automatic-resolution \
    >"$workdir/resolve.log" 2>&1 || {
    cat "$workdir/resolve.log" >&2
    echo "FAIL: cannot resolve the locked AxolotyZenoh dependencies" >&2
    exit 1
}
json_checkout="$workdir/swiftpm/checkouts/swift-json"
json_core_dir="$json_checkout/Sources/_JSONCore"
[ -d "$json_core_dir" ] || {
    echo "FAIL: resolved swift-json _JSONCore source is missing: $json_core_dir" >&2
    exit 1
}
expected_revision=$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).jsonCore.revision);' "$root_dir/docs/embedded-consumer-contract.json")
actual_revision=$(git -C "$json_checkout" rev-parse HEAD)
[ "$actual_revision" = "$expected_revision" ] || {
    echo "FAIL: AxolotyZenoh locks swift-json $actual_revision; the embedded consumer contract pins $expected_revision" >&2
    exit 1
}

embedded_swiftc() {
    swiftc \
        -target riscv32-none-none-eabi \
        -swift-version 6 \
        -enable-experimental-feature Embedded \
        -enable-experimental-feature Lifetimes \
        -parse-as-library -Osize -wmo \
        -I "$workdir" \
        "$@"
}

swift_sources() {
    for source in "$@"; do
        [ -f "$source" ] && printf '%s\n' "$source"
    done
}

echo "Compiling _JSONCore as Embedded Swift..."
# shellcheck disable=SC2046 # Source paths contain no whitespace.
embedded_swiftc \
    -package-name IkigaJSON \
    -module-name _JSONCore \
    -emit-module -emit-module-path "$workdir/_JSONCore.swiftmodule" \
    -c $(swift_sources "$json_core_dir"/*.swift "$json_core_dir"/Parser/*.swift "$json_core_dir"/SIMD/*.swift) \
    -o "$workdir/_JSONCore.o"

echo "Compiling AxolotyWire as Embedded Swift..."
# shellcheck disable=SC2046
embedded_swiftc \
    -module-name AxolotyWire \
    -emit-module -emit-module-path "$workdir/AxolotyWire.swiftmodule" \
    -c $(swift_sources "$wire_dir"/*.swift) \
    -o "$workdir/AxolotyWire.o"

# SwiftPM synthesizes this module for the façade's public headers; spell it
# out so the Embedded compile imports the same single header.
mkdir -p -- "$workdir/CAxolotyZenoh"
cat >"$workdir/CAxolotyZenoh/module.modulemap" <<EOF
module CAxolotyZenoh {
    header "$facade_header"
    export *
}
EOF

echo "Compiling AxolotyZenohCore as Embedded Swift..."
# shellcheck disable=SC2046
embedded_swiftc \
    -warnings-as-errors \
    -module-name AxolotyZenohCore \
    -Xcc -fmodule-map-file="$workdir/CAxolotyZenoh/module.modulemap" \
    -emit-module -emit-module-path "$workdir/AxolotyZenohCore.swiftmodule" \
    -c $(swift_sources "$zenoh_core_dir"/*.swift) \
    -o "$workdir/AxolotyZenohCore.o"

find_riscv_linker() {
    swiftc_bin=$(CDPATH= cd -- "$(dirname -- "$(command -v swiftc)")" && pwd)
    for candidate in \
        "$swiftc_bin/ld.lld" \
        "$swiftc_bin/../lib/llvm/bin/ld.lld" \
        /usr/lib/swift/llvm/bin/ld.lld \
        /usr/local/swift/usr/bin/ld.lld \
        /usr/bin/ld.lld; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v ld.lld 2>/dev/null && return 0
    echo "FAIL: no RISC-V-capable ld.lld found for the Zenoh core partial link" >&2
    return 1
}

echo "Partially linking AxolotyZenohCore with AxolotyWire..."
riscv_linker=$(find_riscv_linker)
"$riscv_linker" -r \
    -o "$workdir/embedded-zenoh-core-linked.o" \
    "$workdir/AxolotyZenohCore.o" \
    "$workdir/AxolotyWire.o" \
    "$workdir/_JSONCore.o"

# A relocatable link has no libc or firmware image. Only the C façade entry
# points and the runtime symbols the Core gate already allows may remain.
nm "$workdir/embedded-zenoh-core-linked.o" >"$workdir/linked-symbols.txt"
unresolved_symbols=$(awk '$1 ~ /^[UuWwVv]$/ { print $2 } $2 ~ /^[UuWwVv]$/ { print $3 }' "$workdir/linked-symbols.txt")
facade_symbols=0
unexpected_symbols=$(for symbol in $unresolved_symbols; do
    case "$symbol" in
        axoloty_zenoh_*) ;;
        \$e*|_swift_*|swift_*|__swift_assignWithCopy_strong|__swift_assignWithTake_strong|__swift_destroy_strong|__swift_initWithCopy_strong|__swift_memcpy4_4|__adddf3|__ashldi3|__divdf3|__floatunsidf|__lshrdi3|__muldf3|__nedf2|__stack_chk_fail|__stack_chk_guard|__udivdi3|arc4random_buf|free|memcpy|memmove|memset|posix_memalign) ;;
        *) printf '%s\n' "$symbol" ;;
    esac
done)
if [ -n "$unexpected_symbols" ]; then
    echo "FAIL: Zenoh core partial link leaves unexpected unresolved symbols:" >&2
    printf '%s\n' "$unexpected_symbols" >&2
    exit 1
fi
for symbol in $unresolved_symbols; do
    case "$symbol" in axoloty_zenoh_*) facade_symbols=$((facade_symbols + 1)) ;; esac
done
[ "$facade_symbols" -gt 0 ] || {
    echo "FAIL: AxolotyZenohCore no longer references the C façade; the gate proves nothing" >&2
    exit 1
}

linked_size=$(wc -c <"$workdir/embedded-zenoh-core-linked.o")
echo "EMBEDDED SWIFT ZENOH CORE OK — AxolotyZenohCore and AxolotyWire compiled for riscv32-none-none-eabi; ${facade_symbols} façade symbols left for firmware: ${linked_size} bytes"
