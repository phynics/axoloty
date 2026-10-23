#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Verify clean root-package consumers. Revision mode is the immutable public
# acquisition path; local mode remains a synthetic pre-release fixture only.

set -eu
unset GIT_DIR GIT_WORK_TREE

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
canonical_url=https://github.com/phynics/axoloty.git
url=${AXOLOTY_CONSUMER_REPOSITORY_URL:-$canonical_url}
version=${AXOLOTY_CONSUMER_VERSION:-}
revision=${AXOLOTY_CONSUMER_REVISION:-}
local_mode=${AXOLOTY_CONSUMER_LOCAL:-0}
jobs=${AXOLOTY_CONSUMER_JOBS:-2}
evidence=${AXOLOTY_CONSUMER_EVIDENCE_DIR:-}
platform=${AXOLOTY_CONSUMER_PLATFORM:-unspecified}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
empty_gitconfig="$work/empty-gitconfig"
: >"$empty_gitconfig"
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
for config_name in $(env | sed -n 's/^\(GIT_CONFIG_KEY_[0-9][0-9]*\)=.*/\1/p; s/^\(GIT_CONFIG_VALUE_[0-9][0-9]*\)=.*/\1/p'); do
    unset "$config_name"
done
export GIT_CONFIG_GLOBAL="$empty_gitconfig" GIT_CONFIG_NOSYSTEM=1

fail() {
    echo "error: $*" >&2
    exit 1
}

case "$jobs" in
    [1-9]|[1-9][0-9]*) : ;;
    *) fail "AXOLOTY_CONSUMER_JOBS must be a positive integer: $jobs" ;;
esac

if [ "$local_mode" != 1 ] && [ "$url" != "$canonical_url" ]; then
    fail "non-synthetic consumer validation requires canonical repository URL: $canonical_url"
fi

if [ -n "$revision" ]; then
    [ "$local_mode" = 0 ] || fail "revision mode cannot use AXOLOTY_CONSUMER_LOCAL"
    case "$revision" in
        *[!0-9a-f]*|'') fail "AXOLOTY_CONSUMER_REVISION must be a lowercase immutable git revision" ;;
    esac
    [ "${#revision}" -eq 40 ] || fail "AXOLOTY_CONSUMER_REVISION must contain 40 hex characters"
    ref_kind=revision
    ref_value=$revision
else
    [ -n "$version" ] || {
        [ -f "$root/VERSION" ] || fail "VERSION is missing"
        version=$(tr -d '[:space:]' < "$root/VERSION")
    }
    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) fail "AXOLOTY_CONSUMER_VERSION must be semver: $version" ;;
    esac
    ref_kind=version
    ref_value=$version
fi

if [ "$local_mode" = 1 ]; then
    [ -z "$revision" ] || fail "synthetic local mode cannot be combined with a revision"
    local_version=${AXOLOTY_CONSUMER_LOCAL_VERSION:-9.9.9}
    source="$work/source"
    mkdir "$source"
    (cd "$root" && tar --exclude=.git --exclude=.build --exclude=.testing -cf - .) | (cd "$source" && tar -xf -)
    rm -rf "$source/.git"

    # This synthetic mirror exists only to exercise pre-release semver wiring.
    json_source="$work/swift-json-source"
    git clone -q https://github.com/phynics/swift-json.git "$json_source"
    json_revision=$(git -C "$json_source" rev-list -n 1 2.5.3)
    [ "$json_revision" = ec81216be5bbe2f02f45831d05256de2af452be8 ] || fail "swift-json 2.5.3 resolved to unexpected revision: $json_revision"
    json_bare="$work/swift-json.git"
    git clone -q --bare "$json_source" "$json_bare"
    cat >"$work/gitconfig" <<EOF
[url "file://$json_bare/"]
    insteadOf = https://github.com/phynics/swift-json.git
EOF

    git -C "$source" init -q
    git -C "$source" config user.email axoloty-check@example.invalid
    git -C "$source" config user.name axoloty-check
    git -C "$source" add .
    git -C "$source" commit -qm "synthetic semver consumer fixture"
    bare="$work/axoloty.git"
    git -C "$source" tag "v$local_version"
    git clone -q --bare "$source" "$bare"
    url="file://$bare"
    version=$local_version
    ref_value=$version
    export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
fi

if [ -z "$evidence" ]; then
    evidence="$root/.build/external-consumer-evidence/$(date -u +%Y%m%dT%H%M%SZ)-$ref_value"
fi
mkdir -p "$evidence"
evidence=$(CDPATH= cd -- "$evidence" && pwd)

# Ignore user SwiftPM mirrors and keep its configuration and scratch private.
HOME="$work/home"
mkdir -p "$HOME"
export HOME

consumer="$work/consumer"
mkdir -p "$consumer/Sources/WireConsumer" "$consumer/Sources/PortableConsumer" \
    "$consumer/Sources/MQTTConsumer" "$consumer/Sources/TransportSPIConsumer"
if [ -n "$revision" ]; then
    package_requirement=".package(url: \"$url\", revision: \"$revision\")"
else
    package_requirement=".package(url: \"$url\", from: \"$version\")"
fi
cat >"$consumer/Package.swift" <<EOF
// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "AxolotyExternalConsumer",
    dependencies: [$package_requirement],
    targets: [
        .executableTarget(name: "WireConsumer", dependencies: [
            .product(name: "AxolotyWire", package: "axoloty"),
        ]),
        .executableTarget(name: "PortableConsumer", dependencies: [
            .product(name: "AxolotyProtocol", package: "axoloty"),
            .product(name: "AxolotyObjectModel", package: "axoloty"),
            .product(name: "AxolotyStaticRuntime", package: "axoloty"),
        ]),
        .executableTarget(name: "MQTTConsumer", dependencies: [
            .product(name: "Axoloty", package: "axoloty"),
            .product(name: "AxolotyMQTT", package: "axoloty"),
        ]),
        .executableTarget(name: "TransportSPIConsumer", dependencies: [
            .product(name: "Axoloty", package: "axoloty"),
            .product(name: "AxolotyProtocol", package: "axoloty"),
            .product(name: "AxolotyWire", package: "axoloty"),
        ]),
    ]
)
EOF
cat >"$consumer/Sources/WireConsumer/main.swift" <<'EOF'
import AxolotyWire

let bytes = Array(#"{"object":{}}"#.utf8)
let found = bytes.withUnsafeBufferPointer { buffer in
    guard let baseAddress = buffer.baseAddress else { return false }
    let reader = WireReader(bytes: baseAddress, length: buffer.count)
    return reader.readField("object") != nil
}
guard found else { fatalError("wire object lookup failed") }
print("AXOLOTY_WIRE_CONSUMER_OK")
EOF
cat >"$consumer/Sources/PortableConsumer/main.swift" <<'EOF'
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyStaticRuntime

let objectID = ObjectID(uuid: .zero)
let runtime = try StaticRuntimeTiny(registryID: objectID)
let classification = ProtocolRouteClassification.coaty
guard runtime.maximumPayloadBytes == 2048, classification == .coaty else {
    fatalError("portable products did not initialize")
}
print("AXOLOTY_PORTABLE_CONSUMER_OK")
EOF
cat >"$consumer/Sources/MQTTConsumer/main.swift" <<'EOF'
import Axoloty
import AxolotyMQTT

let identity = try RuntimeIdentity(id: .zero, name: "external-consumer")
var builder = try RuntimeBuilder(identity: identity, namespace: "consumer")
let definition = try builder.finish()
let binding = try MQTTBinding(configuration: MQTTBindingConfiguration(host: "localhost", port: 1883))
_ = AxolotyRuntime(definition: definition, transport: binding)
print("AXOLOTY_MQTT_CONSUMER_LINKED")
EOF
cat >"$consumer/Sources/TransportSPIConsumer/main.swift" <<'EOF'
import Axoloty
import AxolotyProtocol
import AxolotyWire
import Foundation

final class RecordingTransport: AxolotyRuntimeTransport, @unchecked Sendable {
    let capabilities: RuntimeTransportCapabilities = []
    let wireProfile: WireProfile = .coaty3JSON
    private let lock = NSLock()
    private var started = false
    private var effectCount = 0

    func start(
        receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
        lastWill: RuntimeTransportLastWill?
    ) async throws(AxolotyError) {
        _ = receive
        _ = lastWill
        lock.withLock { started = true }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async { _ = handler }
    func setRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async { _ = handler }
    func setDiagnostics(_ diagnostics: RuntimeTransportDiagnostics) async { _ = diagnostics }

    func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError) {
        _ = effect
        lock.withLock { effectCount += 1 }
    }

    func stop() async {
        lock.withLock { started = false }
    }

    func classifyRoute(_ route: ByteSlice) -> ProtocolRouteClassification {
        route.length == 0 ? .unrelated : .coaty
    }

    func snapshot() -> (Bool, Int) {
        lock.withLock { (started, effectCount) }
    }
}

@main
enum Consumer {
    static func main() async throws {
        let identity = try RuntimeIdentity(id: .zero, name: "spi-consumer")
        var builder = try RuntimeBuilder(identity: identity, namespace: "consumer")
        let definition = try builder.finish()
        let transport = RecordingTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()
        let started = await runtime.lifecycleState() == .running
        let (transportStarted, effects) = transport.snapshot()
        await runtime.stop()
        let stopped = await runtime.lifecycleState() == .stopped
        guard started, transportStarted, effects > 0, stopped else {
            fatalError("public transport SPI lifecycle or effect delivery failed")
        }
        print("AXOLOTY_TRANSPORT_SPI_BEHAVIOR_OK effects=\(effects)")
    }
}
EOF

cd "$consumer"
swift --version >"$evidence/swift-version.txt"
uname -a >"$evidence/platform.txt"
cp Package.swift "$evidence/Package.swift"
. "$root/Tests/Support/lib/consumer-provenance.sh"
axoloty_check_consumer_paths "$root" "$consumer" || exit 1

swift package resolve >"$evidence/resolve.log" 2>&1 || { cat "$evidence/resolve.log" >&2; fail "fresh remote resolution failed"; }
swift package show-dependencies --format flatlist >"$evidence/dependencies.txt"
cp Package.resolved "$evidence/Package.resolved"

if [ -n "$revision" ]; then
    axoloty_check_core_pin "$evidence/Package.resolved" "$url" "$revision" || exit 1
fi

for configuration in debug release; do
    for target in WireConsumer PortableConsumer MQTTConsumer TransportSPIConsumer; do
        log="$evidence/build-$configuration-$target.log"
        if ! swift build --jobs "$jobs" --configuration "$configuration" --target "$target" >"$log" 2>&1; then
            cat "$log" >&2
            fail "$configuration build failed for $target"
        fi
    done
    if grep -Eq 'Compiling (MQTTNIO|NIO|NIOCore|NIOPosix|NIOSSL|Logging|ErrorKit) ' "$evidence/build-$configuration-WireConsumer.log"; then
        cat "$evidence/build-$configuration-WireConsumer.log" >&2
        fail "Wire-only target built host runtime targets"
    fi
    for executable in WireConsumer PortableConsumer MQTTConsumer TransportSPIConsumer; do
        log="$evidence/run-$configuration-$executable.log"
        if ! swift run --jobs "$jobs" --configuration "$configuration" "$executable" >"$log" 2>&1; then
            cat "$log" >&2
            fail "$configuration linked execution failed for $executable"
        fi
    done
    grep -Fqx AXOLOTY_WIRE_CONSUMER_OK "$evidence/run-$configuration-WireConsumer.log" || fail "Wire consumer execution marker missing"
    grep -Fqx AXOLOTY_PORTABLE_CONSUMER_OK "$evidence/run-$configuration-PortableConsumer.log" || fail "portable consumer execution marker missing"
    grep -Fqx AXOLOTY_MQTT_CONSUMER_LINKED "$evidence/run-$configuration-MQTTConsumer.log" || fail "MQTT consumer execution marker missing"
    grep -Eq '^AXOLOTY_TRANSPORT_SPI_BEHAVIOR_OK effects=[1-9][0-9]*$' "$evidence/run-$configuration-TransportSPIConsumer.log" || fail "transport SPI behavior marker missing"
done

resolved_revision=$(python3 - "$evidence/Package.resolved" "$url" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    pins = json.load(source).get("pins", [])
matches = [pin for pin in pins if pin.get("location") == sys.argv[2]]
print(matches[0]["state"].get("revision", "") if len(matches) == 1 else "unavailable")
PY
)
evidence_mode=public-remote
[ "$local_mode" = 1 ] && evidence_mode=synthetic-local-file-remote
cat >"$evidence/provenance.txt" <<EOF
repository_url=$url
requested_kind=$ref_kind
requested_value=$ref_value
resolved_core_revision=$resolved_revision
evidence_mode=$evidence_mode
platform_label=$platform
evidence_directory=$evidence
EOF

echo "Axoloty external consumers passed in debug/release; provenance: $evidence/provenance.txt"
