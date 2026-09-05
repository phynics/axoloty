#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Audit the current product graph after the G4 runtime migration. Historical
# compatibility fixtures remain valid, but current host and static products
# must not grow a second transport/protocol implementation or pull the
# SensorThings extension into the root Axoloty product.

set -eu

root=${AXOLOTY_G6_PRODUCT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)}
fail() { echo "G6 PRODUCT BOUNDARY FAIL: $*" >&2; exit 1; }

manifest="$root/Package.swift"
[ -f "$manifest" ] || fail "missing root Package.swift"

target_block=$(awk '
    /^[[:space:]]*\.target\(/ {
        in_target=1
        buffer=$0
        found=0
        next
    }
    in_target {
        buffer=buffer "\n" $0
        if ($0 ~ /^[[:space:]]*name: "Axoloty",/) found=1
        if (found && $0 ~ /^        \),[[:space:]]*$/) {
            print buffer
            exit
        }
    }
' "$manifest")
printf '%s\n' "$target_block" | grep -q 'name: "Axoloty",' \
    || fail "root Axoloty target is not declared"
printf '%s\n' "$target_block" | grep -Eq 'AxolotyProtocol|AxolotyWire' \
    || fail "root Axoloty target does not use the shared protocol/wire products"
if printf '%s\n' "$target_block" | grep -Eq 'AxolotySensorThings|AxolotyCoatyModels'; then
    fail "extension model target leaked into the root Axoloty product"
fi

for directory in "$root/Source" "$root/Packages/AxolotyStaticRuntime/Sources"; do
    [ -d "$directory" ] || fail "missing current product source directory: $directory"
    matches=$(rg -n --glob '*.swift' \
        '\b(MQTTNIOClient|HostWireEventEncoder|CommunicationManager|PayloadCoder|Container|Controller)\b' \
        "$directory" || true)
    [ -z "$matches" ] || fail "legacy runtime/protocol symbol in current product source:\n$matches"
done

for path in "$root/Packages/AxolotyRuntime" "$root/LegacyCompatibility"; do
    [ ! -e "$path" ] || fail "retired runtime directory remains in the active checkout: $path"
done

printf '{"schemaVersion":1,"status":"passed","rootAxolotyUsesSharedProtocol":true,"sensorThingsSplit":true}\n'
