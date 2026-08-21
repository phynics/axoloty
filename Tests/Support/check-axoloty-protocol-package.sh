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
component="$root/Embedded/swift/components/axoloty_protocol/CMakeLists.txt"

set -- "$source_dir"/*.swift
if [ "$1" = "$source_dir/*.swift" ]; then
    echo "error: AxolotyProtocol has no production Swift sources" >&2
    exit 1
fi

for source in "$@"; do
    if grep -Eq '^[[:space:]]*import[[:space:]]+(Foundation|MQTTNIO|NIO|NIOCore|NIOPosix|Logging|ErrorKit|Combine)[[:space:]]*$' "$source"; then
        echo "error: forbidden host dependency in $source" >&2
        exit 1
    fi
done

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

swift build --package-path "$package_dir" \
    --disable-automatic-resolution \
    --cache-path "$root/.swiftpm-cache" \
    --product AxolotyProtocol

echo "AxolotyProtocol host source inclusion and dependency policy passed"
