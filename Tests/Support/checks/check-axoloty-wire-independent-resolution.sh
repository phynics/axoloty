#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Resolves the downstream AxolotyWire fixture and asserts its exact package
# closure. swift-json is intentional: its disabled FoundationSupport trait
# exposes only IkigaJSONCore. Its swift-nio package is resolution-only and
# must not be built or linked by this fixture.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
fixture="$root/Packages/AxolotyWire/Fixtures/DownstreamConsumer"

cd "$fixture"
swift package resolve
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT
swift build >"$build_log" 2>&1
deps=$(swift package show-dependencies --format flatlist)

expected_dependencies=$(printf '%s\n' \
    axolotywire \
    swift-json \
    swift-nio \
    swift-atomics \
    swift-collections \
    swift-system \
    | sort)
actual_dependencies=$(printf '%s\n' "$deps" | sed '/^[[:space:]]*$/d' | sort)
if [ "$actual_dependencies" != "$expected_dependencies" ]; then
    echo "error: standalone AxolotyWire resolved an unexpected package closure" >&2
    echo "expected:" >&2
    printf '%s\n' "$expected_dependencies" >&2
    echo "actual:" >&2
    printf '%s\n' "$actual_dependencies" >&2
    exit 1
fi
if grep -Eq 'Compiling (NIO|NIOCore|NIOFoundationCompat|NIOPosix) ' "$build_log"; then
    echo "error: a swift-nio target was built for the standalone AxolotyWire fixture" >&2
    exit 1
fi

echo "AxolotyWire resolved its allowlisted standalone closure without host runtime targets"
