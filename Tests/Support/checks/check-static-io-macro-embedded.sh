#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Type-checks a real macro-expanded static IO handler against the portable
# modules produced for the ESP32-C6 target. The macro plugin runs on the host;
# its generated C-convention trampoline is checked for riscv32 Embedded Swift.

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
embedded_dir="$root_dir/.build/embedded-swift/esp-idf"
fixture="$root_dir/Tests/Support/fixtures/StaticIoActorEmbeddedConsumer.swift"
macro_tool=$(find "$root_dir/.build" -type f \
    -name 'AxolotyStaticRuntimeMacrosImplementation-tool' -print -quit)

[ -n "$macro_tool" ] || {
    echo "static IO macro implementation tool is missing; run the root build first" >&2
    exit 1
}
for component in json_core axoloty_wire axoloty_object_model axoloty_protocol axoloty_static_runtime; do
    [ -d "$embedded_dir/$component" ] || {
        echo "embedded module directory is missing: $component" >&2
        exit 1
    }
done

swiftc \
    -typecheck \
    -parse-as-library \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -load-plugin-executable "$macro_tool#AxolotyStaticRuntimeMacrosImplementation" \
    -I "$embedded_dir/json_core" \
    -I "$embedded_dir/axoloty_wire" \
    -I "$embedded_dir/axoloty_object_model" \
    -I "$embedded_dir/axoloty_protocol" \
    -I "$embedded_dir/axoloty_static_runtime" \
    "$fixture"

echo "STATIC IO MACRO EMBEDDED CONSUMER OK"
