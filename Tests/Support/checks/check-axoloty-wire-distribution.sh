#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validate the two supported AxolotyWire consumption topologies separately:
#
#   root package      -> full package resolution, wire-only target closure
#   standalone package -> independent package resolution and wire-only closure
#
# The root product is useful to consumers already using Axoloty, but selecting
# its wire product does not narrow SwiftPM's package-resolution graph. The
# standalone package is the supported acquisition boundary for consumers that
# need wire-only package resolution.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

assert_marker() {
    log=$1
    marker=$2
    if ! grep -Fqx "$marker" "$log"; then
        echo "error: consumer did not execute successfully: $marker" >&2
        cat "$log" >&2
        exit 1
    fi
}

assert_no_host_targets() {
    log=$1
    if grep -Eq 'Compiling (MQTTNIO|NIO|NIOCore|NIOPosix|NIOSSL|Logging|ErrorKit) ' "$log"; then
        echo "error: wire-only consumer built host runtime targets" >&2
        cat "$log" >&2
        exit 1
    fi
}

root_consumer="$work/root-consumer"
mkdir -p "$root_consumer/Sources/RootWireConsumer"
cat >"$root_consumer/Package.swift" <<EOF
// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "RootWireConsumer",
    dependencies: [.package(path: "$root")],
    targets: [
        .executableTarget(
            name: "RootWireConsumer",
            dependencies: [.product(name: "AxolotyWire", package: "workspace")]
        ),
    ]
)
EOF
cat >"$root_consumer/Sources/RootWireConsumer/main.swift" <<'EOF'
import AxolotyWire

print("AXOLOTY_WIRE_ROOT_CONSUMER_OK")
_ = UUID16.zero
EOF

cd "$root_consumer"
swift package resolve
swift package show-dependencies --format flatlist >"$work/root-resolution.log"
for required in mqtt-nio swift-nio ErrorKit; do
    if ! grep -qi "$required" "$work/root-resolution.log"; then
        echo "error: root AxolotyWire product did not resolve the expected host graph member: $required" >&2
        cat "$work/root-resolution.log" >&2
        exit 1
    fi
done

swift build --configuration debug --target RootWireConsumer >"$work/root-build.log" 2>&1
assert_no_host_targets "$work/root-build.log"
if ! swift run --configuration debug RootWireConsumer >"$work/root-run.log" 2>&1; then
    echo "error: root AxolotyWire consumer failed to link or run" >&2
    cat "$work/root-run.log" >&2
    exit 1
fi
assert_marker "$work/root-run.log" "AXOLOTY_WIRE_ROOT_CONSUMER_OK"

standalone_checker="$root/Tests/Support/checks/check-axoloty-wire-independent-resolution.sh"
sh "$standalone_checker"

standalone_fixture="$root/Packages/AxolotyWire/Fixtures/DownstreamConsumer"
cd "$standalone_fixture"
if ! swift run --configuration debug DownstreamConsumer >"$work/standalone-run.log" 2>&1; then
    echo "error: standalone AxolotyWire consumer failed to link or run" >&2
    cat "$work/standalone-run.log" >&2
    exit 1
fi
assert_marker "$work/standalone-run.log" "AXOLOTY_WIRE_STANDALONE_CONSUMER_OK"

# The contract documents `--disable-default-traits` for a CBOR-only consumer.
# Build the standalone wire package both ways under SwiftPM and prove the
# default-enabled CoatyJSON trait is what links the JSON parser. The build
# writes `Package.resolved` next to the standalone manifest; remove it unless
# it existed before.
standalone_wire="$root/Packages/AxolotyWire"
standalone_resolved="$standalone_wire/Package.resolved"
had_standalone_resolved=0
if [ -e "$standalone_resolved" ]; then had_standalone_resolved=1; fi
cleanup_standalone_resolved() {
    if [ "$had_standalone_resolved" -eq 0 ] && [ -e "$standalone_resolved" ]; then
        rm -f "$standalone_resolved"
    fi
    return 0
}
trap 'cleanup_standalone_resolved; rm -rf "$work"' EXIT

if ! swift build \
    --package-path "$standalone_wire" \
    --scratch-path "$work/wire-default" \
    --configuration debug >"$work/wire-default.log" 2>&1; then
    echo "error: standalone AxolotyWire default build failed" >&2
    cat "$work/wire-default.log" >&2
    exit 1
fi
if ! grep -Eq '_JSONCore' "$work/wire-default.log"; then
    echo "error: the default CoatyJSON trait did not build _JSONCore" >&2
    cat "$work/wire-default.log" >&2
    exit 1
fi

if ! swift build \
    --package-path "$standalone_wire" \
    --scratch-path "$work/wire-cbor" \
    --configuration debug \
    --disable-default-traits >"$work/wire-cbor.log" 2>&1; then
    echo "error: standalone AxolotyWire failed to build with --disable-default-traits" >&2
    cat "$work/wire-cbor.log" >&2
    exit 1
fi
if grep -Eq '_JSONCore' "$work/wire-cbor.log"; then
    echo "error: --disable-default-traits still built _JSONCore" >&2
    cat "$work/wire-cbor.log" >&2
    exit 1
fi
cleanup_standalone_resolved

echo "AxolotyWire CoatyJSON trait gates the JSON parser under SwiftPM"
echo "AxolotyWire root and standalone distribution boundaries validated"
