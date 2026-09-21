#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Checks the portable object-model package boundary. The model may depend on
# AxolotyWire only; host-runtime layers do not belong in this portable package.
# Schema and predicate types are part of the object-model boundary and are
# intentionally allowed here.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
package_dir=${AXOLOTY_OBJECT_MODEL_PACKAGE_DIR:-$root/Packages/AxolotyObjectModel}
source_dir="$package_dir/Sources/AxolotyObjectModel"
manifest="$package_dir/Package.swift"
root_manifest=${AXOLOTY_ROOT_MANIFEST:-$root/Package.swift}
coaty_package_dir=${AXOLOTY_COATY_MODELS_PACKAGE_DIR:-$root/Packages/AxolotyCoatyModels}
coaty_source_dir="$coaty_package_dir/Sources/AxolotyCoatyModels"
coaty_manifest=${AXOLOTY_COATY_MODELS_MANIFEST:-$coaty_package_dir/Package.swift}

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
    if grep -Eq '^[[:space:]]*@MainActor([[:space:]]|$)|^[[:space:]]*@globalActor([[:space:]]|$)|^[[:space:]]*(distributed[[:space:]]+)?actor[[:space:]]|^[[:space:]]*(class|struct|enum|protocol)[[:space:]]+[A-Za-z0-9_]*(Controller|Lifecycle|HostObject)[[:space:]]*[{:]' "$source"; then
        echo "error: host-runtime isolation in $source" >&2
        exit 1
    fi
done

if [ ! -f "$manifest" ]; then
    echo "error: missing AxolotyObjectModel Package.swift" >&2
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
if [ ! -f "$root_manifest" ]; then
    echo "error: missing root Package.swift" >&2
    exit 1
fi
if ! grep -Fq '.library(' "$root_manifest" || \
   ! grep -Fq 'name: "AxolotyObjectModel"' "$root_manifest" || \
   ! grep -Fq 'targets: ["AxolotyObjectModel"]' "$root_manifest"; then
    echo "error: root package does not publish AxolotyObjectModel" >&2
    exit 1
fi
if ! grep -Fq 'dependencies: ["AxolotyWire"]' "$root_manifest" || \
   ! grep -Fq 'path: "Packages/AxolotyObjectModel/Sources/AxolotyObjectModel"' "$root_manifest"; then
    echo "error: root AxolotyObjectModel target has the wrong dependency closure" >&2
    exit 1
fi
if ! grep -Fq 'name: "AxolotyObjectModelTests"' "$root_manifest" || \
   ! grep -Fq 'dependencies: ["AxolotyObjectModel", "AxolotyWire"]' "$root_manifest" || \
   ! grep -Fq 'path: "Packages/AxolotyObjectModel/Tests/AxolotyObjectModelTests"' "$root_manifest"; then
    echo "error: root AxolotyObjectModel test target is not wired to the standalone tests" >&2
    exit 1
fi
if [ ! -f "$coaty_manifest" ] || [ ! -d "$coaty_source_dir" ]; then
    echo "error: missing AxolotyCoatyModels package sources" >&2
    exit 1
fi
set -- "$coaty_source_dir"/*.swift
if [ "$1" = "$coaty_source_dir/*.swift" ]; then
    echo "error: AxolotyCoatyModels has no production Swift sources" >&2
    exit 1
fi
for source in "$@"; do
    if grep -Eq '^[[:space:]]*import[[:space:]]+(Foundation|MQTTNIO|NIO|NIOCore|NIOPosix|NIOHTTP1|Logging|OSLog|ErrorKit|Combine)[[:space:]]*$' "$source"; then
        echo "error: forbidden host dependency in $source" >&2
        exit 1
    fi
done
coaty_manifest_without_comments=$(sed -E 's://.*$::' "$coaty_manifest")
if ! printf '%s' "$coaty_manifest_without_comments" | grep -Fq 'name: "AxolotyCoatyModels"' || \
   ! printf '%s' "$coaty_manifest_without_comments" | grep -Fq 'Sources/AxolotyCoatyModels'; then
    echo "error: AxolotyCoatyModels manifest is not source-wired" >&2
    exit 1
fi
if ! printf '%s' "$coaty_manifest_without_comments" | grep -Fq 'path: "../AxolotyObjectModel"'; then
    echo "error: AxolotyCoatyModels must depend on AxolotyObjectModel" >&2
    exit 1
fi
if ! grep -Fq 'name: "AxolotyCoatyModels"' "$root_manifest" || \
   ! grep -Fq 'targets: ["AxolotyCoatyModels"]' "$root_manifest" || \
   ! grep -Fq 'path: "Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels"' "$root_manifest"; then
    echo "error: root package does not publish AxolotyCoatyModels" >&2
    exit 1
fi
if ! grep -Fq 'name: "AxolotyCoatyModelsTests"' "$root_manifest" || \
   ! grep -Fq 'path: "Packages/AxolotyCoatyModels/Tests/AxolotyCoatyModelsTests"' "$root_manifest"; then
    echo "error: root package does not wire AxolotyCoatyModels tests" >&2
    exit 1
fi
if [ "${AXOLOTY_OBJECT_MODEL_SKIP_BUILD:-0}" != "1" ]; then
    swift build --package-path "$package_dir" \
        --scratch-path "$root/.build/packages/axoloty-object-model" \
        --disable-automatic-resolution \
        --cache-path "$root/.swiftpm-cache" \
        --target AxolotyObjectModel
fi
if [ "${AXOLOTY_COATY_MODELS_SKIP_BUILD:-${AXOLOTY_OBJECT_MODEL_SKIP_BUILD:-0}}" != "1" ]; then
    swift build --package-path "$coaty_package_dir" \
        --scratch-path "$root/.build/packages/axoloty-coaty-models" \
        --disable-automatic-resolution \
        --cache-path "$root/.swiftpm-cache" \
        --target AxolotyCoatyModels
fi

echo "AxolotyObjectModel host source inclusion and dependency policy passed"
