#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-g4-runtime-consumer-boundary.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_fixture() {
    rm -rf "$tmp/Packages" "$tmp/Source" "$tmp/Consumers"
    mkdir -p "$tmp/Source/Runtime" "$tmp/Packages/AxolotyStaticRuntime" "$tmp/Consumers/Inspector"
    : > "$tmp/Source/Runtime/AxolotyRuntime.swift"
    : > "$tmp/Packages/AxolotyStaticRuntime/Package.swift"
    printf '%s\n' 'import AxolotyRuntime' 'struct InspectorFixture {}' > "$tmp/Consumers/Inspector/Fixture.swift"
}

run_checker() {
    AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR="$tmp/Source/Runtime" \
    AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR="$tmp/Packages/AxolotyStaticRuntime" \
    AXOLOTY_G4_CONSUMER_ROOTS="$tmp/Consumers/Inspector" \
        "$checker"
}

run_historical_checker() {
    AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR="$tmp/Source/Runtime" \
    AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR="$tmp/Packages/AxolotyStaticRuntime" \
    AXOLOTY_G4_CONSUMER_ROOTS="$tmp/Consumers/Inspector" \
    AXOLOTY_G4_HISTORICAL_CONSUMER_ROOTS="$tmp/Consumers/Inspector" \
        "$checker"
}

write_fixture
run_checker >/dev/null

write_fixture
printf '%s\n' 'import Axoloty' >> "$tmp/Consumers/Inspector/Fixture.swift"
if run_checker >/dev/null 2>&1; then
    echo "error: consumer checker accepted the inherited Axoloty import" >&2
    exit 1
fi

write_fixture
printf '%s\n' 'let manager: CommunicationManager? = nil' >> "$tmp/Consumers/Inspector/Fixture.swift"
if run_checker >/dev/null 2>&1; then
    echo "error: consumer checker accepted a legacy manager" >&2
    exit 1
fi

write_fixture
printf '%s\n' 'import MQTTNIO' >> "$tmp/Consumers/Inspector/Fixture.swift"
if run_checker >/dev/null 2>&1; then
    echo "error: consumer checker accepted a raw MQTT dependency" >&2
    exit 1
fi

write_fixture
printf '%s\n' 'import Axoloty' >> "$tmp/Consumers/Inspector/Fixture.swift"
run_historical_checker >/dev/null

echo "G4 runtime consumer boundary negative tests passed"
