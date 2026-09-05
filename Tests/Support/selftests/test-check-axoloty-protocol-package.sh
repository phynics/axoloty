#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Negative self-test for the #638 dependency boundary. The maintained checker
# must reject every prohibited host/runtime boundary independently.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

copy_package() {
    rm -rf "$tmp/package"
    mkdir -p "$tmp/package"
    cp "$root/Packages/AxolotyProtocol/AGENTS.md" "$tmp/package/"
    cp "$root/Packages/AxolotyProtocol/Package.swift" "$root/Packages/AxolotyProtocol/Package.resolved" "$tmp/package/"
    cp -R "$root/Packages/AxolotyProtocol/Sources" "$root/Packages/AxolotyProtocol/Tests" "$tmp/package/"
}

check_source_rejected() {
    label=$1
    mutation=$2
    copy_package
    echo "$mutation" >> "$tmp/package/Sources/AxolotyProtocol/ProtocolError.swift"
    if AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/package" "$root/Tests/Support/checks/check-axoloty-protocol-package.sh" >/dev/null 2>&1; then
        echo "error: checker accepted $label boundary" >&2
        exit 1
    fi
}

check_source_rejected "Foundation" "import Foundation"
check_source_rejected "MQTT" "import MQTTNIO"
check_source_rejected "NIO" "import NIOHTTP1"
check_source_rejected "logging" "import Logging"
check_source_rejected "global actor" "@MainActor struct HostFacade {}"
check_source_rejected "actor" "actor ForbiddenActor {}"
check_source_rejected "controller" "struct ForbiddenController {}"
check_source_rejected "lifecycle" "struct ForbiddenLifecycle {}"
check_source_rejected "host object" "struct ForbiddenHostObject {}"

copy_package
sed -i 's/\.product(name: "AxolotyWire", package: "AxolotyWire")/.product(name: "NIO", package: "swift-nio")/' "$tmp/package/Package.swift"
if AXOLOTY_PROTOCOL_PACKAGE_DIR="$tmp/package" "$root/Tests/Support/checks/check-axoloty-protocol-package.sh" >/dev/null 2>&1; then
    echo "error: checker accepted forbidden manifest dependency" >&2
    exit 1
fi

echo "AxolotyProtocol forbidden-boundary negative tests passed"
