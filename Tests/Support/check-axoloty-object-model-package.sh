#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Checks the portable object-model package boundary and its ESP-IDF source
# inclusion. The model may depend on AxolotyWire only; host-runtime layers do
# not belong in this portable package. Schema and predicate types are part of
# the object-model boundary and are intentionally allowed here.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
package_dir=${AXOLOTY_OBJECT_MODEL_PACKAGE_DIR:-$root/Packages/AxolotyObjectModel}
source_dir="$package_dir/Sources/AxolotyObjectModel"
manifest="$package_dir/Package.swift"
component=${AXOLOTY_OBJECT_MODEL_COMPONENT:-$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt}
main_component=${AXOLOTY_OBJECT_MODEL_MAIN_COMPONENT:-$root/Embedded/swift/main/CMakeLists.txt}

set -- "$source_dir"/*.swift
if [ "$1" = "$source_dir/*.swift" ]; then
    echo "error: AxolotyObjectModel has no production Swift sources" >&2
    exit 1
fi

for source in "$@"; do
    if grep -Eq '^[[:space:]]*import[[:space:]]+(Foundation|MQTTNIO|NIO|NIOCore|NIOPosix|NIOHTTP1|NIOConcurrencyHelpers|Logging|OSLog|ErrorKit|Combine)[[:space:]]*$' "$source"; then
        echo "error: forbidden host dependency in $source" >&2
        exit 1
    fi
    if grep -Eq '^[[:space:]]*@MainActor([[:space:]]|$)|^[[:space:]]*(distributed[[:space:]]+)?actor[[:space:]]' "$source"; then
        echo "error: host-runtime isolation in $source" >&2
        exit 1
    fi
done

if [ ! -f "$manifest" ]; then
    echo "error: missing AxolotyObjectModel Package.swift" >&2
    exit 1
fi
if [ ! -f "$component" ]; then
    echo "error: missing AxolotyObjectModel ESP-IDF component" >&2
    exit 1
fi
if [ ! -f "$main_component" ]; then
    echo "error: missing embedded main component" >&2
    exit 1
fi

manifest_without_comments=$(sed -E 's://.*$::' "$manifest")
package_entries=$(printf '%s' "$manifest_without_comments" | grep -E '^[[:space:]]*\.package\(' || true)
package_entry_count=$(printf '%s' "$package_entries" | awk 'NF { count++ } END { print count + 0 }')
if [ "$package_entry_count" -ne 1 ] || ! printf '%s' "$package_entries" | grep -Fq '.package(path: "../AxolotyWire")'; then
    echo "error: AxolotyObjectModel must have exactly one local AxolotyWire package dependency" >&2
    exit 1
fi
if printf '%s' "$manifest_without_comments" | grep -Eq '(Foundation|MQTTNIO|NIO|Logging|OSLog|ErrorKit|Combine)'; then
    echo "error: forbidden host/runtime manifest dependency" >&2
    exit 1
fi
if ! grep -Fq 'AxolotyObjectModel/Sources/AxolotyObjectModel/*.swift' "$component"; then
    echo "error: ESP-IDF component does not compile the AxolotyObjectModel source glob" >&2
    exit 1
fi
if ! grep -Fq 'AxolotyWire' "$component" || ! grep -Fq 'AxolotyObjectModel' "$component"; then
    echo "error: ESP-IDF component does not declare the model/wire module boundary" >&2
    exit 1
fi
if ! grep -Fq 'OUTPUT ${AXOLOTY_OBJECT_MODEL_MODULE_ALIAS}' "$component" || \
   ! grep -Fq 'add_custom_target(axoloty_object_model_module_alias' "$component"; then
    echo "error: ESP-IDF component does not publish an explicit model module output" >&2
    exit 1
fi
if ! grep -Fq 'add_dependencies(${COMPONENT_LIB} axoloty_object_model_module_alias)' "$main_component"; then
    echo "error: embedded main does not depend on the model module output" >&2
    exit 1
fi

swift build --package-path "$package_dir" \
    --disable-automatic-resolution \
    --cache-path "$root/.swiftpm-cache" \
    --product AxolotyObjectModel

echo "AxolotyObjectModel host source inclusion and dependency policy passed"
