#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce the G3 portable object-model package boundary. This checker is
# intentionally source-level: the production packages are expected to be
# independently buildable, and the Embedded Swift component must compile the
# same object-model source glob. It does not claim that G3 is implemented when
# either package or its source inclusion is absent.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
model=${AXOLOTY_OBJECT_MODEL_PACKAGE_DIR:-$root/Packages/AxolotyObjectModel}
macros=${AXOLOTY_OBJECT_MACROS_PACKAGE_DIR:-$root/Packages/AxolotyObjectMacros}
coaty=${AXOLOTY_COATY_MODELS_PACKAGE_DIR:-$root/Packages/AxolotyCoatyModels}
component=${AXOLOTY_OBJECT_MODEL_COMPONENT_DIR:-$root/Embedded/swift/components/axoloty_object_model}

fail() {
    echo "error: $*" >&2
    exit 1
}

test -d "$model" || fail "missing AxolotyObjectModel package: $model"
test -d "$macros" || fail "missing AxolotyObjectMacros package: $macros"
test -d "$coaty" || fail "missing AxolotyCoatyModels package: $coaty"
test -f "$model/Package.swift" || fail "missing AxolotyObjectModel Package.swift"
test -f "$macros/Package.swift" || fail "missing AxolotyObjectMacros Package.swift"
test -f "$model/Package.resolved" || fail "missing AxolotyObjectModel Package.resolved"
test -f "$macros/Package.resolved" || fail "missing AxolotyObjectMacros Package.resolved"
test -f "$model/AGENTS.md" || fail "missing AxolotyObjectModel AGENTS.md"
test -f "$macros/AGENTS.md" || fail "missing AxolotyObjectMacros AGENTS.md"
test -f "$coaty/Package.swift" || fail "missing AxolotyCoatyModels Package.swift"

model_sources="$model/Sources"
macro_sources="$macros/Sources"
coaty_sources="$coaty/Sources"
model_source_list=$(find "$model_sources" -type f -name '*.swift' -print)
macro_source_list=$(find "$macro_sources" -type f -name '*.swift' -print)
coaty_source_list=$(find "$coaty_sources" -type f -name '*.swift' -print)
[ -n "$model_source_list" ] || fail "AxolotyObjectModel has no production Swift sources"
[ -n "$macro_source_list" ] || fail "AxolotyObjectMacros has no production Swift sources"
[ -n "$coaty_source_list" ] || fail "AxolotyCoatyModels has no production Swift sources"

check_source_policy() {
    package=$1
    shift
    source_list=$1
    for source in $source_list; do
        if grep -Eq '^[[:space:]]*import[[:space:]]+(Foundation|MQTTNIO|NIO|NIOCore|NIOPosix|NIOHTTP1|NIOConcurrencyHelpers|Logging|OSLog|ErrorKit|Combine)([[:space:]]|$)' "$source"; then
            fail "forbidden host dependency in $package source $source"
        fi
        if grep -Eq '^[[:space:]]*@MainActor([[:space:]]|$)|^[[:space:]]*@globalActor([[:space:]]|$)|^[[:space:]]*(distributed[[:space:]]+)?actor[[:space:]]|^[[:space:]]*(class|struct|enum|protocol)[[:space:]]+[A-Za-z0-9_]*(Controller|Lifecycle|HostObject)[[:space:]]*[{:]' "$source"; then
            fail "actor/controller/lifecycle/host boundary in $package source $source"
        fi
        if grep -Eq '^[[:space:]]*(public[[:space:]]+|internal[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+)?static[[:space:]]+var[[:space:]]+[^({=]+=' "$source"; then
            fail "global mutable/static state in $package source $source"
        fi
        if grep -Eq '\b(Array|Dictionary)\b' "$source"; then
            fail "growable Array/Dictionary storage in $package source $source"
        fi
    done
}

check_source_policy AxolotyObjectModel "$model_source_list"
check_source_policy AxolotyObjectMacros "$macro_source_list"
check_source_policy AxolotyCoatyModels "$coaty_source_list"

model_manifest=$(sed -E 's:^[[:space:]]*//.*$::' "$model/Package.swift")
macro_manifest=$(sed -E 's:^[[:space:]]*//.*$::' "$macros/Package.swift")
coaty_manifest=$(sed -E 's:^[[:space:]]*//.*$::' "$coaty/Package.swift")

printf '%s' "$model_manifest" | grep -Fq 'name: "AxolotyObjectModel"' || fail "AxolotyObjectModel manifest has no matching package/target name"
printf '%s' "$model_manifest" | grep -Fq 'Sources/AxolotyObjectModel' || fail "AxolotyObjectModel manifest omits its source path"
model_package_entries=$(printf '%s' "$model_manifest" | grep -E '^[[:space:]]*\.package\(' || true)
model_package_count=$(printf '%s' "$model_package_entries" | awk 'NF { count++ } END { print count + 0 }')
[ "$model_package_count" -le 1 ] || fail "AxolotyObjectModel has more than one package dependency"
if printf '%s' "$model_manifest" | grep -Eiq '(Foundation|MQTTNIO|mqtt-nio|swift-nio|Logging|swift-log|OSLog|ErrorKit|Combine|Actor|Controller|Lifecycle)'; then
    fail "forbidden manifest dependency or host boundary in AxolotyObjectModel"
fi

printf '%s' "$macro_manifest" | grep -Fq 'name: "AxolotyObjectMacros"' || fail "AxolotyObjectMacros manifest has no matching package/target name"
test -d "$macros/Sources/AxolotyObjectMacros" || fail "AxolotyObjectMacros omits its default source path"
printf '%s' "$macro_manifest" | grep -Fq 'swift-syntax' || fail "AxolotyObjectMacros must declare SwiftSyntax"
printf '%s' "$macro_manifest" | grep -Eq '603\.[0-9]+' || fail "AxolotyObjectMacros must pin SwiftSyntax 603.x"
grep -Fq 'swift-syntax' "$macros/Package.resolved" || fail "AxolotyObjectMacros Package.resolved omits SwiftSyntax"
grep -Eq '"version"[[:space:]]*:[[:space:]]*"603\.[0-9]+' "$macros/Package.resolved" || fail "AxolotyObjectMacros Package.resolved must pin SwiftSyntax 603.x"
if printf '%s' "$macro_manifest" | grep -Eiq '(Foundation|MQTTNIO|mqtt-nio|swift-nio|Logging|swift-log|OSLog|ErrorKit|Combine|Actor|Controller|Lifecycle)'; then
    fail "forbidden manifest dependency or host boundary in AxolotyObjectMacros"
fi

printf '%s' "$coaty_manifest" | grep -Fq 'name: "AxolotyCoatyModels"' || fail "AxolotyCoatyModels manifest has no matching package name"
printf '%s' "$coaty_manifest" | grep -Fq 'Sources/AxolotyCoatyModels' || fail "AxolotyCoatyModels manifest omits its source path"
if printf '%s' "$coaty_manifest" | grep -Eiq '(Foundation|MQTTNIO|mqtt-nio|swift-nio|Logging|swift-log|OSLog|ErrorKit|Combine|Actor|Controller|Lifecycle)'; then
    fail "forbidden manifest dependency or host boundary in AxolotyCoatyModels"
fi

test -f "$component/CMakeLists.txt" || fail "missing Embedded Swift object-model component"
component_text=$(sed -E 's:#.*$::' "$component/CMakeLists.txt")
printf '%s' "$component_text" | grep -Fq 'Packages/AxolotyObjectModel/Sources/AxolotyObjectModel/*.swift' || fail "Embedded Swift component omits the object-model source glob"
printf '%s' "$component_text" | grep -Fq 'idf_component_register_swift' || fail "Embedded Swift component does not register Swift sources"

echo "AxolotyObjectModel/AxolotyObjectMacros boundary and source inclusion passed"
