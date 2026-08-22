#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce migration of first-party tools and examples after the replacement
# runtime is available. Existing 0.5 consumers remain valid until that point;
# this gate prevents a partial G4 migration from silently retaining the old
# hierarchy or a raw MQTT path.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime_package=${AXOLOTY_G4_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyRuntime}
runtime_source_dir=${AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR:-$root/Source/Runtime}
static=${AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyStaticRuntime}
consumer_roots=${AXOLOTY_G4_CONSUMER_ROOTS:-"$root/Tools/AxolotyInspectorRuntime $root/Tools/AxolotyInspectorRuntimeTests $root/Tools/AxolotyInspectorCLITests $root/Tools/AxolotyMCP $root/Tools/AxolotyMCPTests $root/Tools/axoloty-inspect $root/Tools/axoloty-mcp $root/Examples"}
historical_roots=${AXOLOTY_G4_HISTORICAL_CONSUMER_ROOTS:-"$root/Tools/AxolotyInspectorRuntime $root/Tools/AxolotyInspectorRuntimeTests $root/Tools/AxolotyInspectorCLITests $root/Tools/AxolotyMCP $root/Tools/AxolotyMCPTests $root/Tools/axoloty-inspect $root/Tools/axoloty-mcp"}

fail() {
    echo "error: $*" >&2
    exit 1
}

host_sources=$(find "$runtime_package/Sources" -type f -name '*.swift' -print 2>/dev/null || true)
if [ -z "$host_sources" ]; then
    host_sources=$(find "$runtime_source_dir" -maxdepth 1 -type f -name 'AxolotyRuntime*.swift' -print 2>/dev/null || true)
fi

if [ -z "$host_sources" ] && [ ! -d "$static" ]; then
    echo "G4 runtime consumer migration deferred: replacement runtime roots are not present"
    exit 0
fi

[ -n "$host_sources" ] || fail "replacement host runtime source seam is missing"
[ -d "$static" ] || fail "replacement static runtime package is missing: $static"

for consumer in $consumer_roots; do
    [ -d "$consumer" ] || continue
    historical=0
    for historical_root in $historical_roots; do
        if [ "$consumer" = "$historical_root" ]; then
            historical=1
            break
        fi
    done
    if [ "$historical" -eq 1 ]; then
        echo "G4 consumer migration deferred for historical consumer: $consumer"
        continue
    fi
    sources=$(find "$consumer" -type f \( -name '*.swift' -o -name 'Package.swift' \) -print)
    for source in $sources; do
        if grep -Eq '^[[:space:]]*import[[:space:]]+Axoloty([[:space:]]|$)|\b(Container|Controller|CommunicationManager|MQTTNIO|MQTTClient|PayloadCoder)\b' "$source"; then
            fail "legacy runtime or raw transport dependency in migrated consumer: $source"
        fi
    done
done

echo "G4 first-party consumer boundary passed"
