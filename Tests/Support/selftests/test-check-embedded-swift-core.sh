#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for the Core-owned Embedded Swift consumer gate (issue #850).
# The real check is intentionally run twice: once against the production
# fixture and once against a malformed fixture. The second run proves that a
# consumer source failure cannot be hidden by successful Core module builds.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-embedded-swift-core.sh"
[ -x "$checker" ] || {
    echo "checker is not executable: $checker" >&2
    exit 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM
macro_scratch=${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR:-$tmpdir/macro-tools}

# A nonexistent firmware project and SDK must not affect this Core-only gate.
if ! AXOLOTY_SOURCE_DIR="$root" \
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    EMBEDDED_PROJECT_DIR="$tmpdir/missing-firmware" \
    IDF_PATH="$tmpdir/missing-sdk" \
    "$checker" >"$tmpdir/pass.log" 2>&1; then
    cat "$tmpdir/pass.log" >&2
    echo "expected Core-owned Embedded Swift checker to pass" >&2
    exit 1
fi
grep -Fq 'five portable modules' "$tmpdir/pass.log"
echo "  PASS: five portable modules and real StaticIoActor consumer compile/link"
echo "  PASS: missing firmware and SDK paths are irrelevant"

# Reuse the macro/dependency preparation from the successful run. This keeps
# the negative test focused on the consumer source rather than dependency
# setup, and avoids an unnecessary second cold SwiftPM build.
macro_tool=$(find "$macro_scratch" -type f -name AxolotyStaticRuntimeMacrosImplementation-tool -perm -111 -print -quit)
[ -n "$macro_tool" ] || {
    echo "could not locate prepared StaticIoActor macro tool" >&2
    exit 1
}
cp "$root/Tests/Support/fixtures/StaticIoActorEmbeddedConsumer.swift" "$tmpdir/BadConsumer.swift"
printf '\nthis is not valid Swift source\n' >>"$tmpdir/BadConsumer.swift"

if AXOLOTY_SOURCE_DIR="$root" \
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR="$macro_scratch" \
    AXOLOTY_STATIC_RUNTIME_MACRO_TOOL="$macro_tool" \
    AXOLOTY_EMBEDDED_CORE_FIXTURE="$tmpdir/BadConsumer.swift" \
    EMBEDDED_PROJECT_DIR="$tmpdir/also-missing-firmware" \
    "$checker" >"$tmpdir/fail.log" 2>&1; then
    cat "$tmpdir/fail.log" >&2
    echo "malformed consumer unexpectedly passed" >&2
    exit 1
fi
echo "  PASS: malformed Embedded consumer source is rejected"

# Keep this check auditable: this gate must not grow a hidden firmware/SDK
# dependency while its manifest remains a hardware-free CI requirement.
if grep -Eq 'Embedded/swift|ESP-IDF|idf\.py|IDF_PATH' "$checker"; then
    echo "Core checker contains a firmware or SDK dependency" >&2
    exit 1
fi
echo "  PASS: checker source has no firmware or ESP-IDF dependency"

echo ""
echo "SELF-TEST OK (4 checks passed, 0 failed)"
