#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
spike="$root/Spikes/NativeWireCodec"
wire="$root/Packages/AxolotyWire/Sources/AxolotyWire"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift run -c release --package-path "$spike" --disable-automatic-resolution
bin_path=$(swift build -c release --package-path "$spike" \
    --disable-automatic-resolution --show-bin-path)
echo "hostReleaseExecutableBytes=$(wc -c < "$bin_path/NativeWireCodecProbe")"

swift_files=""
for file in "$wire"/*.swift; do swift_files="$swift_files $file"; done

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded -parse-as-library -Osize -wmo \
    -module-name AxolotyWire -emit-module -c $swift_files \
    -o "$work/AxolotyWire.o" \
    -emit-module-path "$work/AxolotyWire.swiftmodule"

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded -parse-as-library -Osize -wmo \
    -I "$work" \
    -c "$spike/Sources/NativeWireCodecProbe/ProbeCore.swift" \
       "$spike/embedded-probe.swift" \
    -o "$work/native-spike.o"

echo "embeddedAxolotyWireObjectBytes=$(wc -c < "$work/AxolotyWire.o")"
echo "embeddedNativeSpikeObjectBytes=$(wc -c < "$work/native-spike.o")"
echo "NATIVE HOST + EMBEDDED COMPILE OK"
