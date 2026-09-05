#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
package=${AXOLOTY_G5_PACKAGE_DIR:-$root/Packages/AxolotySensorThings}
runtime="$package/Sources/AxolotySensorThings/SensorThingsRuntime.swift"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$package/AGENTS.md" ] || fail "SensorThings package policy is missing"
[ -f "$runtime" ] || fail "SensorThings runtime source is missing"
[ -f "$package/Tests/AxolotySensorThingsTests/SensorThingsSourceWorkflowTests.swift" ] || fail "source workflow tests are missing"
[ -f "$package/Tests/AxolotySensorThingsTests/SensorThingsDirectObservationTests.swift" ] || fail "direct observation tests are missing"
[ -f "$package/Sources/AxolotySensorThings/SensorThingsRegistry.swift" ] || fail "Thing-driven registry source is missing"
[ -f "$package/Tests/AxolotySensorThingsTests/SensorThingsRegistryTests.swift" ] || fail "registry tests are missing"

grep -q 'mutating func sensorThings' "$runtime" || fail "atomic sensorThings builder API is missing"
swift_sources=$(find "$package/Sources" "$package/Tests" -type f -name '*.swift' -print)
if printf '%s\n' "$swift_sources" | xargs grep -lEq 'SensorThings(Source|Observer)Configuration|sensorThings(Source|Observer)[[:space:]]*[(]' 2>/dev/null; then
    fail "retired SensorThings configuration API remains"
fi
if grep -Eq 'axoloty\.sensor-things\.(source|observer)|Task\.detached|RuntimeComponent' "$runtime"; then
    fail "SensorThings runtime has more than one module or an unowned task path"
fi
grep -q 'SensorThingsRegistryTests' "$root/Tests/Support/test-tiers.json" || fail "registry tests are not in the G5 tier"

echo "G5 optional-products boundary passed"
