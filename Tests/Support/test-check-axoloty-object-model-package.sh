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

check_source_rejected() {
    label=$1
    mutation=$2
    copy_package
    echo "$mutation" >> "$tmp/package/Sources/AxolotyObjectModel/Primitives.swift"
    if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
       AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
       "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
        echo "error: checker accepted $label boundary" >&2
        exit 1
    fi
}

check_source_rejected "Foundation" "import Foundation"
check_source_rejected "host transport" "import MQTTNIO"
check_source_rejected "predicate" "struct ForbiddenPredicate {}"
check_source_rejected "schema" "struct ForbiddenSchema {}"

copy_package
sed -i 's/\.product(name: "AxolotyWire", package: "AxolotyWire")/.product(name: "NIO", package: "swift-nio")/' "$tmp/package/Package.swift"
if AXOLOTY_OBJECT_MODEL_PACKAGE_DIR="$tmp/package" \
   AXOLOTY_OBJECT_MODEL_COMPONENT="$root/Embedded/swift/components/axoloty_object_model/CMakeLists.txt" \
   "$root/Tests/Support/check-axoloty-object-model-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted forbidden manifest dependency" >&2
    exit 1
fi

echo "AxolotyObjectModel forbidden-boundary negative tests passed"
