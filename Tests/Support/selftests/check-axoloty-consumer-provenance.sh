#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$root/Tests/Support/lib/consumer-provenance.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

consumer="$work/consumer"
mkdir -p "$consumer/Sources/Consumer"
cat >"$consumer/Package.swift" <<'EOF'
// swift-tools-version:6.4
import PackageDescription
let package = Package(name: "Consumer", dependencies: [.package(url: "https://github.com/phynics/axoloty.git", revision: "6f34bcc1fa77da35d23303c51cbfc9a96e583d10")], targets: [])
EOF
printf 'print("ok")\n' >"$consumer/Sources/Consumer/main.swift"
axoloty_check_consumer_paths "$root" "$consumer"

cat >"$consumer/Package.swift" <<EOF
let package = Package(dependencies: [.package(path: "$root")])
EOF
if axoloty_check_consumer_paths "$root" "$consumer" >/dev/null 2>&1; then
    echo "expected path-dependency rejection" >&2
    exit 1
fi

cat >"$consumer/Package.swift" <<'EOF'
let package = Package(name: "Consumer", dependencies: [.package(url: "https://github.com/phynics/axoloty.git", revision: "6f34bcc1fa77da35d23303c51cbfc9a96e583d10")], targets: [])
EOF
printf 'let checkout = "%s"\n' "$root" >"$consumer/Sources/Consumer/main.swift"
if axoloty_check_consumer_paths "$root" "$consumer" >/dev/null 2>&1; then
    echo "expected incidental repository-path rejection" >&2
    exit 1
fi

resolved="$work/Package.resolved"
cat >"$resolved" <<'EOF'
{"pins":[{"identity":"axoloty","kind":"remoteSourceControl","location":"https://github.com/phynics/axoloty.git","state":{"revision":"6f34bcc1fa77da35d23303c51cbfc9a96e583d10"}}]}
EOF
axoloty_check_core_pin "$resolved" https://github.com/phynics/axoloty.git 6f34bcc1fa77da35d23303c51cbfc9a96e583d10
if axoloty_check_core_pin "$resolved" https://github.com/phynics/axoloty.git 1111111111111111111111111111111111111111 >/dev/null 2>&1; then
    echo "expected mismatched resolved revision rejection" >&2
    exit 1
fi

echo "external consumer provenance checks reject paths and mismatched Core pins"
