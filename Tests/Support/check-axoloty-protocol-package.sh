#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Checks the #638 portable package contract without introducing a host-runtime
# dependency. ESP-IDF compiles the identical source glob through the
# axoloty_protocol component; this script checks that the two source lists and
# the forbidden-import policy remain synchronized.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
package_dir=${AXOLOTY_PROTOCOL_PACKAGE_DIR:-$root/Packages/AxolotyProtocol}
source_dir="$package_dir/Sources/AxolotyProtocol"
manifest="$package_dir/Package.swift"
component="$root/Embedded/swift/components/axoloty_protocol/CMakeLists.txt"

set -- "$source_dir"/*.swift
if [ "$1" = "$source_dir/*.swift" ]; then
    echo "error: AxolotyProtocol has no production Swift sources" >&2
    exit 1
fi

for source in "$@"; do
    if grep -Eq '^[[:space:]]*import[[:space:]]+(Foundation|MQTTNIO|NIO|NIOCore|NIOPosix|NIOHTTP1|NIOConcurrencyHelpers|Logging|OSLog|ErrorKit|Combine)[[:space:]]*$' "$source"; then
        echo "error: forbidden host dependency in $source" >&2
        exit 1
    fi
    if grep -Eq '^[[:space:]]*@MainActor([[:space:]]|$)|^[[:space:]]*(distributed[[:space:]]+)?actor[[:space:]]|^[[:space:]]*(class|struct|enum|protocol)[[:space:]]+[A-Za-z0-9_]*(Actor|Controller|Lifecycle|HostObject)[[:space:]]*[{:]' "$source"; then
        echo "error: actor/controller/lifecycle/host boundary in $source" >&2
        exit 1
    fi
done

if [ ! -f "$manifest" ]; then
    echo "error: missing AxolotyProtocol Package.swift" >&2
    exit 1
fi

manifest_without_comments=$(sed -E 's://.*$::' "$manifest")
package_entries=$(printf '%s' "$manifest_without_comments" | grep -E '^[[:space:]]*\.package\(' || true)
package_entry_count=$(printf '%s' "$package_entries" | awk 'NF { count++ } END { print count + 0 }')
if [ "$package_entry_count" -ne 2 ] || \
   ! printf '%s' "$package_entries" | grep -Fq '.package(path: "../AxolotyWire")' || \
   ! printf '%s' "$package_entries" | grep -Fq '.package(path: "../AxolotyObjectModel")'; then
    echo "error: AxolotyProtocol must depend only on AxolotyWire and AxolotyObjectModel" >&2
    exit 1
fi
if printf '%s' "$manifest_without_comments" | grep -Eq '(Foundation|MQTTNIO|NIO|Logging|OSLog|ErrorKit|Combine|Actor|Controller)'; then
    echo "error: forbidden manifest dependency or host boundary" >&2
    exit 1
fi

for source in "$@"; do
    basename=$(basename "$source")
    if ! grep -Fq 'AxolotyProtocol/Sources/AxolotyProtocol/*.swift' "$component"; then
        echo "error: ESP-IDF component does not compile the AxolotyProtocol source glob" >&2
        exit 1
    fi
    case "$basename" in
        *.swift) : ;;
        *) echo "error: unexpected protocol source $source" >&2; exit 1 ;;
    esac
done
if ! grep -Fq 'axoloty_object_model' "$component" || \
   ! grep -Fq 'AxolotyObjectModel.swiftmodule' "$component" || \
   ! grep -Fq 'OBJECT_DEPENDS' "$component"; then
    echo "error: ESP-IDF protocol component does not order AxolotyObjectModel module availability" >&2
    exit 1
fi

swift build --package-path "$package_dir" \
    --scratch-path "$root/.build/packages/axoloty-protocol" \
    --disable-automatic-resolution \
    --cache-path "$root/.swiftpm-cache" \
    --product AxolotyProtocol

echo "AxolotyProtocol host source inclusion and dependency policy passed"
