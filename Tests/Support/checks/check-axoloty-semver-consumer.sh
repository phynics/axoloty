#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Resolve a clean external consumer against a semantic-version requirement.
# Set AXOLOTY_CONSUMER_LOCAL=1 to create a temporary file:// bare remote and
# synthetic tag, which makes this gate usable before a public release exists.

set -eu
unset GIT_DIR GIT_WORK_TREE

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
url=${AXOLOTY_CONSUMER_REPOSITORY_URL:-https://github.com/phynics/axoloty.git}
version=${AXOLOTY_CONSUMER_VERSION:-}
if [ -z "$version" ]; then
    [ -f "$root/VERSION" ] || { echo "error: VERSION is missing" >&2; exit 1; }
    version=$(tr -d '[:space:]' < "$root/VERSION")
fi
local_version=${AXOLOTY_CONSUMER_LOCAL_VERSION:-9.9.9}
jobs=${AXOLOTY_CONSUMER_JOBS:-2}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$version" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "error: AXOLOTY_CONSUMER_VERSION must be semver: $version" >&2; exit 2 ;;
esac
case "$jobs" in
    [1-9]|[1-9][0-9]*) : ;;
    *) echo "error: AXOLOTY_CONSUMER_JOBS must be a positive integer: $jobs" >&2; exit 2 ;;
esac

if [ "${AXOLOTY_CONSUMER_LOCAL:-0}" = "1" ]; then
    source="$work/source"
    mkdir "$source"
    (cd "$root" && tar --exclude=.git --exclude=.build --exclude=.testing -cf - .) | (cd "$source" && tar -xf -)
    rm -rf "$source/.git"

    # Mirror the fork's 2.5.3 release without changing checked-in manifests.
    # Git transports the authentic manifest URL to an isolated bare remote.
    json_source="$work/swift-json-source"
    git clone -q https://github.com/phynics/swift-json.git "$json_source"
    json_revision=$(git -C "$json_source" rev-list -n 1 2.5.3)
    if [ "$json_revision" != "ec81216be5bbe2f02f45831d05256de2af452be8" ]; then
        echo "error: swift-json 2.5.3 resolves to unexpected revision: $json_revision" >&2
        exit 1
    fi
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
    version="$local_version"
fi

consumer="$work/consumer"
mkdir "$consumer"
cat >"$consumer/Package.swift" <<EOF
// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "AxolotySemverConsumer",
    dependencies: [.package(url: "$url", from: "$version")],
    targets: [
        .executableTarget(name: "WireConsumer", dependencies: [.product(name: "AxolotyWire", package: "axoloty")]),
        .executableTarget(name: "AxolotyConsumer", dependencies: [
            .product(name: "Axoloty", package: "axoloty"),
            .product(name: "AxolotyMQTT", package: "axoloty"),
        ]),
    ]
)
EOF
mkdir "$consumer/Sources" "$consumer/Sources/WireConsumer" "$consumer/Sources/AxolotyConsumer"
cat >"$consumer/Sources/WireConsumer/main.swift" <<'EOF'
import AxolotyWire
print("wire consumer")
EOF
cp "$root/Tests/Support/fixtures/semver-consumer/AxolotyConsumer/main.swift" "$consumer/Sources/AxolotyConsumer/main.swift"

cd "$consumer"
if [ "${AXOLOTY_CONSUMER_LOCAL:-0}" = "1" ]; then
    export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
fi
swift package resolve
for configuration in debug release; do
    wire_log="$work/wire-$configuration.log"
    if ! swift build --jobs "$jobs" --configuration "$configuration" --target WireConsumer >"$wire_log" 2>&1; then
        cat "$wire_log" >&2
        exit 1
    fi
    if grep -Eq 'Compiling (MQTTNIO|NIO|NIOCore|NIOPosix|NIOSSL|Logging|ErrorKit) ' "$wire_log"; then
        echo "error: wire-only consumer built host runtime targets" >&2
        cat "$wire_log" >&2
        exit 1
    fi
    axoloty_log="$work/axoloty-$configuration.log"
    if ! swift build --jobs "$jobs" --configuration "$configuration" --target AxolotyConsumer >"$axoloty_log" 2>&1; then
        cat "$axoloty_log" >&2
        exit 1
    fi
done

echo "Axoloty semver consumer resolved $url at $version (debug/release)"
