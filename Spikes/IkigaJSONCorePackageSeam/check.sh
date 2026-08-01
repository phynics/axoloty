#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

spike=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
resolver="$spike/Resolver"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift package resolve --package-path "$resolver"
cp -R "$resolver/.build/checkouts/swift-json" "$work/swift-json"
git -C "$work/swift-json" apply "$spike/expose-core-product.patch"
cp -R "$spike/Consumer" "$work/Consumer"

swift package resolve --package-path "$work/Consumer"
swift run -c release --package-path "$work/Consumer" \
    --disable-automatic-resolution
bin_path=$(swift build -c release --package-path "$work/Consumer" \
    --disable-automatic-resolution --show-bin-path)

swift package show-dependencies --package-path "$work/Consumer" \
    --format json > "$work/dependencies.json"
if ! grep -q 'swift-nio' "$work/dependencies.json"; then
    echo "FAIL: expected swift-nio in the package resolution graph" >&2
    exit 1
fi

core="$work/swift-json/Sources/_JSONCore"
core_files=""
for file in "$core"/*.swift "$core"/Parser/*.swift "$core"/SIMD/*.swift; do
    core_files="$core_files $file"
done

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -parse-as-library -Osize -wmo -package-name IkigaJSON \
    -module-name _JSONCore -emit-module -c $core_files \
    -o "$work/JSONCore.o" \
    -emit-module-path "$work/_JSONCore.swiftmodule"

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -parse-as-library -Osize -wmo -I "$work" \
    -c "$work/Consumer/Sources/CoreConsumer/ProbeCore.swift" \
       "$spike/embedded-probe.swift" \
    -o "$work/embedded-consumer.o"

linker=/usr/lib/swift/llvm/bin/ld.lld
if [ ! -x "$linker" ]; then linker=/usr/bin/ld.lld; fi
"$linker" -r -o "$work/embedded-linked.o" \
    "$work/JSONCore.o" "$work/embedded-consumer.o"

echo "embeddedJSONCoreObjectBytes=$(wc -c < "$work/JSONCore.o")"
echo "embeddedConsumerObjectBytes=$(wc -c < "$work/embedded-consumer.o")"
echo "embeddedLinkedObjectBytes=$(wc -c < "$work/embedded-linked.o")"
echo "hostConsumerExecutableBytes=$(wc -c < "$bin_path/CoreConsumer")"
echo "resolutionIncludesSwiftNIO=yes"
echo "IKIGA JSON CORE PACKAGE SEAM OK"
