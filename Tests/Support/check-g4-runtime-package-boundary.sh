#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce the package boundary for the replacement runtime and the production
# target that hosts it. Once G4 is present, inherited lifecycle, transport,
# and Codable protocol state cannot remain compiled as current implementation.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime_package=${AXOLOTY_G4_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyRuntime}
runtime_source_dir=${AXOLOTY_G4_HOST_RUNTIME_SOURCE_DIR:-$root/Source/Runtime}
static=${AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyStaticRuntime}
production_source_dir=${AXOLOTY_G4_PRODUCTION_SOURCE_DIR:-$root/Source}

fail() {
    echo "error: $*" >&2
    exit 1
}

host_sources=$(find "$runtime_package/Sources" -type f -name '*.swift' -print 2>/dev/null || true)
if [ -z "$host_sources" ]; then
    host_sources=$(find "$runtime_source_dir" -maxdepth 1 -type f \( -name 'AxolotyRuntime*.swift' -o -name 'MQTTBinding.swift' \) -print 2>/dev/null || true)
fi

if [ -z "$host_sources" ] && [ ! -d "$static" ]; then
    echo "G4 runtime package boundary deferred: replacement runtime roots are not present"
    exit 0
fi

[ -n "$host_sources" ] || fail "replacement host runtime source seam is missing"
[ -d "$static" ] || fail "replacement static runtime package is missing: $static"
[ -f "$static/Package.swift" ] || fail "replacement static runtime manifest is missing: $static/Package.swift"

static_sources=$(find "$static/Sources" -type f -name '*.swift' -print 2>/dev/null || true)
[ -n "$static_sources" ] || fail "replacement static runtime package has no Swift sources"
sources="$host_sources $static_sources"
[ -n "$sources" ] || fail "replacement runtime packages have no Swift sources"

for source in $sources; do
    if grep -Eq '\b(Container|Controller|CommunicationManager|PayloadCoder)\b' "$source"; then
        fail "legacy runtime or protocol encoder symbol in replacement source: $source"
    fi
done

production_sources=$(find "$production_source_dir" -type f -name '*.swift' ! -path "$production_source_dir/LegacyCompatibility/*" -print)
violations=0
for source in $production_sources; do
    if grep -Eq '\b(Container|Controller|CommunicationManager|HostWireEventEncoder|MQTTNIOClient|PayloadCoder)\b' "$source"; then
        echo "error: inherited runtime or parallel protocol implementation remains in current production source: $source" >&2
        violations=1
    fi
done
[ "$violations" -eq 0 ] || exit 1

echo "G4 replacement runtime package boundary passed"
