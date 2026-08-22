#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce migration of first-party tools and examples after the replacement
# runtime is available. Existing 0.5 consumers remain valid until that point;
# this gate prevents a partial G4 migration from silently retaining the old
# hierarchy or a raw MQTT path.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime=${AXOLOTY_G4_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyRuntime}
static=${AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyStaticRuntime}
consumer_roots=${AXOLOTY_G4_CONSUMER_ROOTS:-"$root/Tools/AxolotyInspectorRuntime $root/Tools/AxolotyInspectorRuntimeTests $root/Tools/AxolotyMCP $root/Tools/AxolotyMCPTests $root/Tools/axoloty-inspect $root/Tools/axoloty-mcp $root/Examples"}

fail() {
    echo "error: $*" >&2
    exit 1
}

if [ ! -d "$runtime" ] && [ ! -d "$static" ]; then
    echo "G4 runtime consumer migration deferred: replacement runtime roots are not present"
    exit 0
fi

[ -d "$runtime" ] || fail "replacement host runtime package is missing: $runtime"
[ -d "$static" ] || fail "replacement static runtime package is missing: $static"

for consumer in $consumer_roots; do
    [ -d "$consumer" ] || continue
    sources=$(find "$consumer" -type f \( -name '*.swift' -o -name 'Package.swift' \) -print)
    for source in $sources; do
        if grep -Eq '^[[:space:]]*import[[:space:]]+Axoloty([[:space:]]|$)|\b(Container|Controller|CommunicationManager|MQTTNIO|MQTTClient|PayloadCoder)\b' "$source"; then
            fail "legacy runtime or raw transport dependency in migrated consumer: $source"
        fi
    done
done

echo "G4 first-party consumer boundary passed"
