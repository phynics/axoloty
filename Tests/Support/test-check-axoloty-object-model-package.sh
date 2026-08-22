#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Negative self-test for the portable object-model dependency boundary.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

copy_package() {
    rm -rf "$tmp/package"
    mkdir -p "$tmp/package"
    cp "$root/Packages/AxolotyObjectModel/Package.swift" "$root/Packages/AxolotyObjectModel/Package.resolved" "$tmp/package/"
    cp -R "$root/Packages/AxolotyObjectModel/Sources" "$root/Packages/AxolotyObjectModel/Tests" "$tmp/package/"
}

copy_coaty_component() {
    cp "$root/Embedded/swift/components/axoloty_coaty_models/CMakeLists.txt" \
        "$tmp/coaty-models.CMakeLists.txt"
}

check_source_rejected() {
    label=$1
    mutation=$2
    copy_package
    echo "$mutation" >> "$tmp/package/Sources/AxolotyObjectModel/Primitives.swift"
    if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
       AXOLOTY_OBJECT_MODEL_SKIP_BUILD=1 \
       AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
       "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
        echo "error: checker accepted $label boundary" >&2
        exit 1
    fi
}

check_source_allowed() {
    label=$1
    mutation=$2
    copy_package
    echo "$mutation" >> "$tmp/package/Sources/AxolotyObjectModel/Primitives.swift"
    if ! AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
       AXOLOTY_OBJECT_MODEL_SKIP_BUILD=1 \
       AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
       "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
        echo "error: checker rejected allowed $label type" >&2
        exit 1
    fi
}

check_source_rejected "Foundation" "import Foundation"
check_source_rejected "MQTTNIO" "import MQTTNIO"
check_source_rejected "NIO" "import NIO"
check_source_rejected "NIOCore" "import NIOCore"
check_source_rejected "NIOPosix" "import NIOPosix"
check_source_rejected "NIOHTTP1" "import NIOHTTP1"
check_source_rejected "NIOConcurrencyHelpers" "import NIOConcurrencyHelpers"
check_source_rejected "Logging" "import Logging"
check_source_rejected "OSLog" "import OSLog"
check_source_rejected "actor" "actor ForbiddenActor {}"
check_source_rejected "distributed actor" "distributed actor ForbiddenDistributedActor {}"
check_source_rejected "MainActor" "@MainActor struct ForbiddenMainActor {}"
check_source_rejected "custom global actor" "@globalActor enum ForbiddenGlobalActor {}"
check_source_rejected "controller" "struct ForbiddenController {}"
check_source_rejected "lifecycle" "struct ForbiddenLifecycle {}"
check_source_rejected "host object" "struct ForbiddenHostObject {}"
check_source_allowed "schema" "struct ExampleSchema {}"
check_source_allowed "predicate" "struct ExamplePredicate {}"

copy_package
sed -i 's/\.product(name: "AxolotyWire", package: "AxolotyWire")/.product(name: "NIO", package: "swift-nio")/' "$tmp/package/Package.swift"
if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
   AXOLOTY_OBJECT_MODEL_SKIP_BUILD=1 \
   AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
   "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted forbidden manifest dependency" >&2
    exit 1
fi

copy_package
copy_coaty_component
sed -i 's/ axoloty_wire//' "$tmp/coaty-models.CMakeLists.txt"
if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
   AXOLOTY_OBJECT_MODEL_SKIP_BUILD=1 \
   AXOLOTY_COATY_MODELS_SKIP_BUILD=1 \
   AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
   AXOLOTY_COATY_MODELS_COMPONENT="$tmp/coaty-models.CMakeLists.txt" \
   "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted missing AxolotyWire transitive component dependency" >&2
    exit 1
fi

copy_package
copy_coaty_component
sed -i 's/ json_core//' "$tmp/coaty-models.CMakeLists.txt"
if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
   AXOLOTY_OBJECT_MODEL_SKIP_BUILD=1 \
   AXOLOTY_COATY_MODELS_SKIP_BUILD=1 \
   AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
   AXOLOTY_COATY_MODELS_COMPONENT="$tmp/coaty-models.CMakeLists.txt" \
   "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted missing _JSONCore transitive component dependency" >&2
    exit 1
fi

echo "AxolotyObjectModel forbidden-boundary negative tests passed"
