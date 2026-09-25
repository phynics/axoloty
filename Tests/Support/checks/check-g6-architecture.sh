#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validate the G6 source and product boundaries from the portable package
# manifests and the external-consumer contract. Firmware composition is not a
# Core input to this check.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
fail() {
    echo "G6 ARCHITECTURE FAIL: $*" >&2
    exit 1
}

wire_dir="$root/Packages/AxolotyWire/Sources/AxolotyWire"
protocol_dir="$root/Packages/AxolotyProtocol/Sources/AxolotyProtocol"
for path in "$wire_dir" "$protocol_dir" "$root/Packages/AxolotyWire/Package.swift" "$root/Packages/AxolotyProtocol/Package.swift"; do
    test -e "$path" || fail "missing required source boundary path: $path"
done

check_package_path() {
    package=$1
    expected=$2
    manifest="$package/Package.swift"
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

consumer_contract=${AXOLOTY_G6_CONSUMER_REPORT:-$root/docs/embedded-consumer-contract.json}
test -f "$consumer_contract" || fail "consumer contract/report is missing: $consumer_contract"
node - "$consumer_contract" "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [reportPath, root] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const packages = report.portablePackages ?? [];
const names = packages.map(item => item.name ?? item.package);
const expected = ["AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"];
if (JSON.stringify(names) !== JSON.stringify(expected)) {
  throw new Error("consumer report portable package order is not authoritative");
}
for (const item of packages) {
  const source = path.resolve(root, item.sourcePath);
  const expectedSource = path.resolve(root, "Packages", item.name ?? item.package, "Sources", item.name ?? item.package);
  if (source !== expectedSource) {
    throw new Error(`consumer report points ${item.name ?? item.package} outside its portable package source: ${source}`);
  }
  if (!fs.statSync(source).isDirectory()) throw new Error(`missing consumer source directory: ${source}`);
}
const flags = report.swift?.compilerFlags ?? report.swift?.requiredCompilerFlags;
const expectedFlags = ["-swift-version", "6", "-enable-experimental-feature", "Embedded", "-enable-experimental-feature", "Lifetimes"];
if (JSON.stringify(flags) !== JSON.stringify(expectedFlags)) {
  throw new Error("consumer report compiler flags are not the canonical Embedded Swift sequence");
}
const macro = report.staticRuntimeMacro?.executable;
if (typeof macro !== "string" || macro.length === 0 || !report.staticRuntimeMacro?.pluginModule) {
  throw new Error("consumer report does not identify the StaticRuntime macro executable");
}
if (report.contractSHA256 !== undefined && !/^[0-9a-f]{64}$/.test(report.contractSHA256)) {
  throw new Error("consumer preparation report has an invalid contract digest");
}
NODE

wire_sources=$(find "$wire_dir" -maxdepth 1 -type f -name '*.swift' -printf '%f\n' | sort)
protocol_sources=$(find "$protocol_dir" -maxdepth 1 -type f -name '*.swift' -printf '%f\n' | sort)
[ -n "$wire_sources" ] || fail "AxolotyWire has no production Swift sources"
[ -n "$protocol_sources" ] || fail "AxolotyProtocol has no production Swift sources"

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

source_identity="consumer-contract"
if [ "${AXOLOTY_G6_REQUIRE_SOURCE_RECEIPTS:-0}" = "1" ]; then
    host_receipt=${AXOLOTY_G6_HOST_RECEIPT:-}
    embedded_receipt=${AXOLOTY_G6_EMBEDDED_RECEIPT:-}
    [ -n "$host_receipt" ] || fail "host compiler-input receipt is required"
    [ -n "$embedded_receipt" ] || fail "Embedded compiler-input receipt is required"
    [ -f "$host_receipt" ] || fail "host compiler-input receipt is missing: $host_receipt"
    [ -f "$embedded_receipt" ] || fail "Embedded compiler-input receipt is missing: $embedded_receipt"
    node "$root/Tests/Support/evidence/validate-g6-source-receipts.mjs" \
        "$root" "$host_receipt" "$embedded_receipt" >/dev/null
    source_identity="compiler-input-receipts"
fi

if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "${AXOLOTY_G6_SKIP_COPY_CHECK:-0}" != "1" ]; then
    copied_portable=$(git -C "$root" grep -l -E 'struct ProtocolProcessor|enum WireEventType' -- '*.swift' ':!Packages/**' ':!Tests/**' ':!Spikes/**' ':!Tools/**' || true)
    [ -z "$copied_portable" ] || fail "a non-package source copies portable protocol/wire implementation: $copied_portable"
fi

semantic_conditionals=$(rg -n '#if[[:space:]]+(!)?hasFeature\(Embedded\)' \
    "$wire_dir" "$protocol_dir" \
    | grep -Ev 'ByteSlice\.swift|TopicView\.swift|UUID16\.swift' || true)
[ -z "$semantic_conditionals" ] || fail "semantic Embedded conditional remains:\n$semantic_conditionals"

printf '{"schemaVersion":2,"status":"passed","sourceIdentity":"%s","wireSources":%s,"protocolSources":%s,"wireSourceFingerprint":"%s","protocolSourceFingerprint":"%s"}\n' \
    "$source_identity" \
    "$(printf '%s\n' "$wire_sources" | awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\");gsub(/"/,"\\\""); if (n++) printf ","; printf "\"%s\"",$0} END{printf "]"}')" \
    "$(printf '%s\n' "$protocol_sources" | awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\");gsub(/"/,"\\\""); if (n++) printf ","; printf "\"%s\"",$0} END{printf "]"}')" \
    "$wire_fingerprint" "$protocol_fingerprint"
