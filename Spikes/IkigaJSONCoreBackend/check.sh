#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Issue #392: prove whether the pinned swift-json IkigaJSONCore product,
# whose Swift module is named _JSONCore, builds for host and Embedded Swift.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift package resolve --package-path "$root"
checkout="$root/.build/checkouts/swift-json/Sources/_JSONCore"

core_files=""
for file in "$checkout"/*.swift "$checkout"/Parser/*.swift "$checkout"/SIMD/*.swift; do
    core_files="$core_files $file"
done

swiftc -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -parse-as-library -O -wmo -package-name IkigaJSON -module-name _JSONCore \
    -emit-module -c $core_files \
    -o "$work/JSONCore-host.o" \
    -emit-module-path "$work/_JSONCore.swiftmodule"

swiftc -O -I "$work" \
    "$root/Sources/IkigaJSONCoreBackendProbe/ProbeCore.swift" \
    "$root/Sources/IkigaJSONCoreBackendProbe/main.swift" \
    "$work/JSONCore-host.o" \
    -o "$work/host-probe"
"$work/host-probe"

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -parse-as-library -Osize -wmo -package-name IkigaJSON -module-name _JSONCore \
    -emit-module -c $core_files \
    -o "$work/JSONCore.o" \
    -emit-module-path "$work/_JSONCore.swiftmodule"

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -parse-as-library -Osize -wmo -I "$work" \
    -c "$root/Sources/IkigaJSONCoreBackendProbe/ProbeCore.swift" \
       "$root/embedded-probe.swift" \
    -o "$work/embedded-probe.o"

echo "embeddedJSONCoreObjectBytes=$(wc -c < "$work/JSONCore.o")"
echo "embeddedProbeObjectBytes=$(wc -c < "$work/embedded-probe.o")"
echo "hostProbeBytes=$(wc -c < "$work/host-probe")"
echo "IKIGA JSON CORE HOST + EMBEDDED COMPILE OK"
