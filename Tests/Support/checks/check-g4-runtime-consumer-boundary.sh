#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce migration of first-party tools and examples after the replacement
# runtime is available. No current consumer may retain the inherited runtime
# hierarchy or a raw MQTT path; historical fixtures must live under an
# explicitly excluded compatibility path instead.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
runtime_package=${AXOLOTY_G4_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyRuntime}
runtime_source_dir=${AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR:-$root/Source/Runtime}
static=${AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyStaticRuntime}
consumer_roots=${AXOLOTY_G4_CONSUMER_ROOTS:-"$root/Tools/AxolotyInspectorRuntime $root/Tools/AxolotyInspectorRuntimeTests $root/Tools/AxolotyInspectorCLITests $root/Tools/AxolotyMCP $root/Tools/AxolotyMCPTests $root/Tools/axoloty-inspect $root/Tools/axoloty-mcp $root/Benchmarks/Consumers $root/Embedded/swift/main $root/Examples"}

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
    # Generated build/dependency checkouts are not first-party consumers. They
    # can contain unrelated legacy symbols and must never affect this source
    # boundary scan.
    sources=$(find "$consumer" -type f \
        ! -path '*/.build/*' \
        ! -path '*/.swiftpm/*' \
        \( -name '*.swift' -o -name 'Package.swift' \) -print)
    for source in $sources; do
        if grep -Eq '\b(Container|Controller|CommunicationManager|MQTTNIO|MQTTClient|PayloadCoder|HostWireEventEncoder|CommunicationEvent|EventSnapshot)\b' "$source"; then
            fail "legacy runtime or raw transport dependency in migrated consumer: $source"
        fi
    done
done

echo "G4 first-party consumer boundary passed"
