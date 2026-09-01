#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-g5-optional-products.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/Packages/AxolotySensorThings/Sources/AxolotySensorThings" \
    "$tmp/Packages/AxolotySensorThings/Tests/AxolotySensorThingsTests"
printf '%s\n' 'policy' > "$tmp/Packages/AxolotySensorThings/AGENTS.md"
printf '%s\n' 'mutating func sensorThings(' > "$tmp/Packages/AxolotySensorThings/Sources/AxolotySensorThings/SensorThingsRuntime.swift"
printf '%s\n' 'tests' > "$tmp/Packages/AxolotySensorThings/Tests/AxolotySensorThingsTests/SensorThingsSourceWorkflowTests.swift"
printf '%s\n' 'tests' > "$tmp/Packages/AxolotySensorThings/Tests/AxolotySensorThingsTests/SensorThingsDirectObservationTests.swift"

AXOLOTY_G5_PACKAGE_DIR="$tmp/Packages/AxolotySensorThings" "$checker" >/dev/null
printf '%s\n' 'SensorThingsSourceConfiguration' >> "$tmp/Packages/AxolotySensorThings/Sources/AxolotySensorThings/SensorThingsRuntime.swift"
if AXOLOTY_G5_PACKAGE_DIR="$tmp/Packages/AxolotySensorThings" "$checker" >/dev/null 2>&1; then
    echo "error: checker accepted the retired configuration API" >&2
    exit 1
fi

echo "G5 optional-products boundary negative tests passed"
