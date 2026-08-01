#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Issue #392: prove whether the pinned swift-json checkout exports the
# proposed IkigaJSONCore module. Failure is the expected result for this
# throwaway spike; any other result is an unexpected change in the dependency.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$root/.build"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

if swift build --package-path "$root" --build-path "$build_dir" \
    --disable-automatic-resolution >"$log" 2>&1; then
    echo "UNEXPECTED: IkigaJSONCore imported successfully"
    exit 1
fi

if ! grep -Eq "no such module ['\"]IkigaJSONCore['\"]|missing product ['\"]IkigaJSONCore['\"]" "$log"; then
    echo "UNEXPECTED: build failed for a reason other than missing IkigaJSONCore" >&2
    cat "$log" >&2
    exit 1
fi

echo "HOST LINUX: expected blocker — IkigaJSONCore is not importable"
grep -E "no such module|missing product" "$log" || true

embedded_log=$(mktemp)
trap 'rm -f "$log" "$embedded_log"' EXIT
if swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded -parse-as-library -Osize \
    -wmo \
    -c "$root/Sources/IkigaJSONCoreBackendProbe/main.swift" \
    -o "$root/.build/embedded-probe.o" >"$embedded_log" 2>&1; then
    echo "UNEXPECTED: Embedded Swift imported IkigaJSONCore successfully"
    exit 1
fi

if ! grep -Eq "no such module ['\"]IkigaJSONCore['\"]|cannot find module" "$embedded_log"; then
    echo "UNEXPECTED: Embedded Swift failed for an unrelated reason" >&2
    cat "$embedded_log" >&2
    exit 1
fi

echo "EMBEDDED SWIFT: expected blocker — IkigaJSONCore is not importable"
grep -E "no such module|cannot find module" "$embedded_log" || true
echo "RESULT: pinned swift-json exposes IkigaJSON only; no adapter was attempted."
