#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validate the G6 source and product boundaries without maintaining a second
# source-file allowlist. The package source directories remain authoritative;
# this check proves that SwiftPM and ESP-IDF point at those same directories.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() {
    echo "G6 ARCHITECTURE FAIL: $*" >&2
    exit 1
}

wire_dir="$root/Packages/AxolotyWire/Sources/AxolotyWire"
protocol_dir="$root/Packages/AxolotyProtocol/Sources/AxolotyProtocol"
wire_cmake="$root/Embedded/swift/components/axoloty_wire/CMakeLists.txt"
protocol_cmake="$root/Embedded/swift/components/axoloty_protocol/CMakeLists.txt"

for path in "$wire_dir" "$protocol_dir" "$wire_cmake" "$protocol_cmake"; do
    test -e "$path" || fail "missing required source boundary path: $path"
done

check_package_path() {
    package=$1
    expected=$2
    manifest="$package/Package.swift"
    test -f "$manifest" || fail "missing package manifest: $manifest"
    grep -Fq "path: \"Sources/$(basename "$expected")\"" "$manifest" \
        || fail "standalone manifest does not name its source root: $manifest"
}

check_package_path "$root/Packages/AxolotyWire" "$wire_dir"
check_package_path "$root/Packages/AxolotyProtocol" "$protocol_dir"

root_manifest=$(sed -E 's:^[[:space:]]*//.*$::' "$root/Package.swift")
printf '%s' "$root_manifest" | grep -Fq 'path: "Packages/AxolotyWire/Sources/AxolotyWire"' \
    || fail "root SwiftPM manifest does not name AxolotyWire source root"
printf '%s' "$root_manifest" | grep -Fq 'path: "Packages/AxolotyProtocol/Sources/AxolotyProtocol"' \
    || fail "root SwiftPM manifest does not name AxolotyProtocol source root"

wire_text=$(sed -E 's:#.*$::' "$wire_cmake")
protocol_text=$(sed -E 's:#.*$::' "$protocol_cmake")
printf '%s' "$wire_text" | grep -Fq 'Packages/AxolotyWire/Sources/AxolotyWire/*.swift' \
    || fail "ESP-IDF AxolotyWire component does not compile the package source root"
printf '%s' "$protocol_text" | grep -Fq 'Packages/AxolotyProtocol/Sources/AxolotyProtocol/*.swift' \
    || fail "ESP-IDF AxolotyProtocol component does not compile the package source root"

wire_sources=$(find "$wire_dir" -maxdepth 1 -type f -name '*.swift' -printf '%f\n' | sort)
protocol_sources=$(find "$protocol_dir" -maxdepth 1 -type f -name '*.swift' -printf '%f\n' | sort)
[ -n "$wire_sources" ] || fail "AxolotyWire has no production Swift sources"
[ -n "$protocol_sources" ] || fail "AxolotyProtocol has no production Swift sources"

# Emit deterministic fingerprints so a checkpoint artifact can prove which
# production source set was compiled, rather than merely recording a path.
source_fingerprint() {
    directory=$1
    find "$directory" -maxdepth 1 -type f -name '*.swift' -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{print $1}'
}
wire_fingerprint=$(source_fingerprint "$wire_dir")
protocol_fingerprint=$(source_fingerprint "$protocol_dir")

# The processor critical path may not be reimplemented under Embedded.
embedded_copies=$(find "$root/Embedded" -type f -name '*.swift' \
    \( -path '*AxolotyWire*' -o -path '*AxolotyProtocol*' -o -name 'ProtocolProcessor.swift' \) -print)
[ -z "$embedded_copies" ] || fail "Embedded contains a copied portable protocol/wire source: $embedded_copies"

# Parser API availability is allowed. Semantic Embedded branches are not. The
# remaining allowlist names host-only conveniences, not protocol transitions.
semantic_conditionals=$(rg -n '#if[[:space:]]+(!)?hasFeature\(Embedded\)' \
    "$wire_dir" "$protocol_dir" \
    | grep -Ev 'ByteSlice\.swift|TopicView\.swift|UUID16\.swift' || true)
[ -z "$semantic_conditionals" ] || fail "semantic Embedded conditional remains:\n$semantic_conditionals"

printf '{"schemaVersion":1,"status":"passed","wireSources":%s,"protocolSources":%s,"wireSourceFingerprint":"%s","protocolSourceFingerprint":"%s"}\n' \
    "$(printf '%s\n' "$wire_sources" | awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\");gsub(/"/,"\\\""); if (n++) printf ","; printf "\"%s\"",$0} END{printf "]"}')" \
    "$(printf '%s\n' "$protocol_sources" | awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\");gsub(/"/,"\\\""); if (n++) printf ","; printf "\"%s\"",$0} END{printf "]"}')" \
    "$wire_fingerprint" "$protocol_fingerprint"
