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
root_manifest=${AXOLOTY_ROOT_MANIFEST:-$root/Package.swift}
component=${AXOLOTY_OBJECT_MODEL_COMPONENT:-$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt}
component_manifest=${AXOLOTY_OBJECT_MODEL_COMPONENT_MANIFEST:-$root/Embedded/swift/components/axoloty_object_model/idf_component.yml}
main_component=${AXOLOTY_OBJECT_MODEL_MAIN_COMPONENT:-$root/Embedded/swift/main/CMakeLists.txt}
protocol_component=${AXOLOTY_PROTOCOL_COMPONENT:-$root/Embedded/swift/components/axoloty_protocol/CMakeLists.txt}
coaty_package_dir=${AXOLOTY_COATY_MODELS_PACKAGE_DIR:-$root/Packages/AxolotyCoatyModels}
coaty_source_dir="$coaty_package_dir/Sources/AxolotyCoatyModels"
coaty_manifest=${AXOLOTY_COATY_MODELS_MANIFEST:-$coaty_package_dir/Package.swift}
coaty_component=${AXOLOTY_COATY_MODELS_COMPONENT:-$root/Embedded/swift/components/axoloty_coaty_models/CMakeLists.txt}
coaty_component_manifest=${AXOLOTY_COATY_MODELS_COMPONENT_MANIFEST:-$root/Embedded/swift/components/axoloty_coaty_models/idf_component.yml}

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
if [ ! -f "$component" ]; then
    echo "error: missing AxolotyObjectModel ESP-IDF component" >&2
    exit 1
fi
if [ ! -f "$component_manifest" ]; then
    echo "error: missing AxolotyObjectModel ESP-IDF manifest" >&2
    exit 1
fi
if [ ! -f "$main_component" ]; then
    echo "error: missing embedded main component" >&2
    exit 1
fi
if [ ! -f "$protocol_component" ]; then
    echo "error: missing AxolotyProtocol ESP-IDF component" >&2
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
if ! grep -Fq 'AxolotyObjectModel/Sources/AxolotyObjectModel/*.swift' "$component"; then
    echo "error: ESP-IDF component does not compile the AxolotyObjectModel source glob" >&2
    exit 1
fi
if ! grep -Fq 'idf_swift' "$component_manifest" || \
   ! grep -Fq 'idf_swift' "$component" || \
   ! grep -Fq 'axoloty_wire' "$component" || \
   ! grep -Fq 'json_core' "$component"; then
    echo "error: ESP-IDF model component dependencies are incomplete" >&2
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
if ! grep -Fq 'axoloty_object_model' "$main_component" || \
   ! grep -Fq 'add_dependencies(${COMPONENT_LIB} axoloty_object_model_module_alias)' "$main_component"; then
    echo "error: embedded main does not depend on the model module output" >&2
    exit 1
fi
if ! grep -Fq 'OUTPUT ${AXOLOTY_PROTOCOL_MODULE_ALIAS}' "$protocol_component" || \
   ! grep -Fq 'add_custom_target(axoloty_protocol_module_alias' "$protocol_component" || \
   ! grep -Fq 'add_dependencies(${COMPONENT_LIB} axoloty_protocol_module_alias)' "$main_component"; then
    echo "error: protocol module publication is not an explicit main compile dependency" >&2
    exit 1
fi

if [ ! -f "$coaty_manifest" ] || [ ! -d "$coaty_source_dir" ]; then
    echo "error: missing AxolotyCoatyModels package sources" >&2
    exit 1
fi
if [ ! -f "$coaty_component" ] || [ ! -f "$coaty_component_manifest" ]; then
    echo "error: missing AxolotyCoatyModels ESP-IDF component" >&2
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
if ! grep -Fq 'Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels/*.swift' "$coaty_component" || \
   ! grep -Eq '^[[:space:]]*PRIV_REQUIRES[[:space:]].*axoloty_object_model([[:space:]]|$)' "$coaty_component" || \
   ! grep -Eq '^[[:space:]]*PRIV_REQUIRES[[:space:]].*axoloty_wire([[:space:]]|$)' "$coaty_component" || \
   ! grep -Eq '^[[:space:]]*PRIV_REQUIRES[[:space:]].*json_core([[:space:]]|$)' "$coaty_component" || \
   ! grep -Fq 'axoloty_wire' "$coaty_component" || \
   ! grep -Fq 'AxolotyObjectModel.swiftmodule' "$coaty_component" || \
   ! grep -Fq 'AxolotyWire.swiftmodule' "$coaty_component" || \
   ! grep -Fq '_JSONCore.swiftmodule' "$coaty_component" || \
   ! grep -Fq 'WIRE_COMPONENT_BINARY_DIR' "$coaty_component" || \
   ! grep -Fq 'JSON_CORE_COMPONENT_BINARY_DIR' "$coaty_component" || \
   ! grep -Fq '    ${WIRE_COMPONENT_BINARY_DIR}' "$coaty_component" || \
   ! grep -Fq '    ${JSON_CORE_COMPONENT_BINARY_DIR}' "$coaty_component" || \
   ! grep -Fq 'APPEND PROPERTIES OBJECT_DEPENDS "${WIRE_MODULE_ALIAS}"' "$coaty_component" || \
   ! grep -Fq 'APPEND PROPERTIES OBJECT_DEPENDS "${JSON_CORE_MODULE_ALIAS}"' "$coaty_component" || \
   ! grep -Fq 'OUTPUT ${AXOLOTY_COATY_MODELS_MODULE_ALIAS}' "$coaty_component"; then
    echo "error: ESP-IDF CoatyModels component has an incomplete transitive source/module dependency" >&2
    exit 1
fi
if ! grep -Fq 'axoloty_coaty_models' "$main_component" || \
   ! grep -Fq 'add_dependencies(${COMPONENT_LIB} axoloty_coaty_models_module_alias)' "$main_component" || \
   ! grep -Fq 'CoatyModelsModuleConsumer.swift' "$main_component"; then
    echo "error: embedded main does not consume the CoatyModels module output" >&2
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
