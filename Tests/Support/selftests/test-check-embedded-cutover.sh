#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Exercise the embedded cutover checker with synthetic Core and firmware
# checkouts. Each mutation below must be rejected; the clean fixture, the
# delegated firmware boundary audit, and the fallback scan must pass.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
checker="$root/Tests/Support/checks/check-embedded-cutover.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

core="$tmp/core"
external="$tmp/axoloty-embedded"

write_contract() {
    cat > "$core/docs/embedded-consumer-contract.json" <<'JSON'
{
  "schemaVersion": 1,
  "portablePackages": [
    {
      "package": "AxolotyWire",
      "packagePath": "Packages/AxolotyWire",
      "sourcePath": "Packages/AxolotyWire/Sources/AxolotyWire"
    }
  ],
  "jsonCore": {
    "lockPath": "Packages/AxolotyStaticRuntime/Package.resolved"
  }
}
JSON
}

write_contract_escape() {
    cat > "$core/docs/embedded-consumer-contract.json" <<'JSON'
{
  "schemaVersion": 1,
  "portablePackages": [
    {
      "package": "AxolotyWire",
      "packagePath": "Packages/AxolotyWire",
      "sourcePath": "Packages/AxolotyWire/../../escape"
    }
  ],
  "jsonCore": {
    "lockPath": "Packages/AxolotyStaticRuntime/Package.resolved"
  }
}
JSON
}

write_contract_absolute() {
    cat > "$core/docs/embedded-consumer-contract.json" <<'JSON'
{
  "schemaVersion": 1,
  "portablePackages": [
    {
      "package": "AxolotyWire",
      "packagePath": "/tmp/axoloty-wire",
      "sourcePath": "Packages/AxolotyWire/Sources/AxolotyWire"
    }
  ],
  "jsonCore": {
    "lockPath": "Packages/AxolotyStaticRuntime/Package.resolved"
  }
}
JSON
}

write_contract_private() {
    cat > "$core/docs/embedded-consumer-contract.json" <<'JSON'
{
  "schemaVersion": 1,
  "portablePackages": [
    {
      "package": "AxolotyWire",
      "packagePath": "Packages/AxolotyWire",
      "sourcePath": "Tests/Support/copied"
    }
  ],
  "jsonCore": {
    "lockPath": "Packages/AxolotyStaticRuntime/Package.resolved"
  }
}
JSON
}

write_contract_doc() {
    printf '%s\n' 'The only local Core override is AXOLOTY_SOURCE_DIR.' \
        > "$core/docs/embedded-consumer-contract.md"
}

write_contract_doc_without_override() {
    printf '%s\n' 'Select a Core checkout with the documented environment.' \
        > "$core/docs/embedded-consumer-contract.md"
}

write_contract_doc_with_alternative() {
    printf '%s\n' 'Set AXOLOTY_CORE_DIR or AXOLOTY_SOURCE_DIR to select a Core checkout.' \
        > "$core/docs/embedded-consumer-contract.md"
}

write_manifest() {
    cat > "$core/Tests/Support/test-tiers.json" <<'JSON'
{
  "schemaVersion": 2,
  "requiredGates": ["embedded-core-consumer"],
  "nodes": [
    {
      "id": "embedded-core-consumer",
      "required": true,
      "local": true,
      "ci": true,
      "hardware": "forbidden",
      "resources": ["source-tree"],
      "command": {
        "executable": "Tests/Support/checks/check-embedded-swift-core.sh",
        "arguments": [],
        "environment": {},
        "executionContext": "project"
      }
    }
  ],
  "tiers": [
    {"id": "ci", "nodes": ["embedded-core-consumer"]},
    {"id": "release", "nodes": ["embedded-core-consumer"]}
  ]
}
JSON
}

write_manifest_firmware_gate() {
    cat > "$core/Tests/Support/test-tiers.json" <<'JSON'
{
  "schemaVersion": 2,
  "requiredGates": ["embedded-core-consumer", "firmware-gate"],
  "nodes": [
    {
      "id": "embedded-core-consumer",
      "required": true,
      "local": true,
      "ci": true,
      "hardware": "forbidden",
      "resources": ["source-tree"],
      "command": {
        "executable": "Tests/Support/checks/check-embedded-swift-core.sh",
        "arguments": [],
        "environment": {},
        "executionContext": "project"
      }
    },
    {
      "id": "firmware-gate",
      "required": true,
      "local": true,
      "ci": true,
      "hardware": "forbidden",
      "resources": ["source-tree"],
      "command": {
        "executable": "Embedded/swift/main/build.sh",
        "arguments": [],
        "environment": {},
        "executionContext": "project"
      }
    }
  ],
  "tiers": [
    {"id": "ci", "nodes": ["embedded-core-consumer", "firmware-gate"]},
    {"id": "release", "nodes": ["embedded-core-consumer", "firmware-gate"]}
  ]
}
JSON
}

write_manifest_hardware_gate() {
    cat > "$core/Tests/Support/test-tiers.json" <<'JSON'
{
  "schemaVersion": 2,
  "requiredGates": ["embedded-core-consumer"],
  "nodes": [
    {
      "id": "embedded-core-consumer",
      "required": true,
      "local": true,
      "ci": true,
      "hardware": "optional",
      "resources": ["source-tree"],
      "command": {
        "executable": "Tests/Support/checks/check-embedded-swift-core.sh",
        "arguments": [],
        "environment": {},
        "executionContext": "project"
      }
    }
  ],
  "tiers": [
    {"id": "ci", "nodes": ["embedded-core-consumer"]},
    {"id": "release", "nodes": ["embedded-core-consumer"]}
  ]
}
JSON
}

write_manifest_without_consumer() {
    cat > "$core/Tests/Support/test-tiers.json" <<'JSON'
{
  "schemaVersion": 2,
  "requiredGates": ["lint"],
  "nodes": [
    {
      "id": "lint",
      "required": true,
      "local": true,
      "ci": true,
      "hardware": "forbidden",
      "resources": ["source-tree"],
      "command": {
        "executable": "swiftlint",
        "arguments": ["lint"],
        "environment": {},
        "executionContext": "project"
      }
    }
  ],
  "tiers": [
    {"id": "ci", "nodes": ["lint"]},
    {"id": "release", "nodes": ["lint"]}
  ]
}
JSON
}

write_lock() {
    identity=${1:-phynics/axoloty}
    revision=${2:-1111111111111111111111111111111111111111}
    cat > "$external/axoloty-core.lock.json" <<EOF
{
  "schemaVersion": 1,
  "core": {
    "identity": "$identity",
    "url": "https://github.com/phynics/axoloty.git",
    "version": "0.8.2",
    "revision": "$revision",
    "revisionFormat": "git-commit-sha1",
    "consumerContractPath": "docs/embedded-consumer-contract.json"
  }
}
EOF
}

run_checker() {
    "$core/Tests/Support/checks/check-embedded-cutover.sh"
}

run_checker_with_external() {
    AXOLOTY_EMBEDDED_COMPARE_DIR="$external" "$core/Tests/Support/checks/check-embedded-cutover.sh"
}

expect_failure() {
    if run_checker >/dev/null 2>&1; then
        echo "error: the cutover checker accepted $1" >&2
        exit 1
    fi
}

expect_external_failure() {
    if run_checker_with_external >/dev/null 2>&1; then
        echo "error: the cutover checker accepted $1" >&2
        exit 1
    fi
}

# A clean Core checkout passes. The check derives its root from its own path,
# so the fixture carries a copy under Tests/Support/checks/.
mkdir -p "$core/docs" "$core/Tests/Support/checks" \
    "$core/Packages/AxolotyWire/Sources/AxolotyWire" \
    "$core/Packages/AxolotyStaticRuntime"
cp "$checker" "$core/Tests/Support/checks/check-embedded-cutover.sh"
printf '%s\n' 'struct CoreOnlyFixture {}' \
    > "$core/Packages/AxolotyWire/Sources/AxolotyWire/CoreOnlyFixture.swift"
printf '%s\n' '{}' > "$core/Packages/AxolotyStaticRuntime/Package.resolved"
write_contract
write_contract_doc
write_manifest
run_checker >/dev/null

# The contract must keep every path inside the checkout and out of private
# Core layout.
write_contract_escape
expect_failure "a contract source path that escapes the checkout"
write_contract_absolute
expect_failure "an absolute contract path"
write_contract_private
expect_failure "a contract path into private Core layout"
write_contract
run_checker >/dev/null

# AXOLOTY_SOURCE_DIR must be the only documented local Core override.
write_contract_doc_without_override
expect_failure "a contract document without AXOLOTY_SOURCE_DIR"
write_contract_doc_with_alternative
expect_failure "a contract document with an alternative Core override"
write_contract_doc
run_checker >/dev/null

# The required canonical plan must stay firmware-free and hardware-free.
write_manifest_firmware_gate
expect_failure "a required gate that runs a firmware-owned script"
write_manifest_hardware_gate
expect_failure "a required gate that permits hardware"
write_manifest_without_consumer
expect_failure "a required plan without the firmware-free consumer gate"
write_manifest
run_checker >/dev/null

# An external checkout is audited only when one is supplied.
mkdir -p "$external/Tools" "$external/docs"
write_lock
cat > "$external/Tools/check-invariants.sh" <<'EOF'
#!/bin/sh
test -n "${AXOLOTY_CORE_COMPARE_DIR:-}" || exit 2
test -d "$AXOLOTY_CORE_COMPARE_DIR/Packages" || exit 3
exit "${AXOLOTY_TEST_INVARIANTS_EXIT:-0}"
EOF
run_checker_with_external >/dev/null

if AXOLOTY_TEST_INVARIANTS_EXIT=1 AXOLOTY_EMBEDDED_COMPARE_DIR="$external" \
    "$core/Tests/Support/checks/check-embedded-cutover.sh" >/dev/null 2>&1; then
    echo "error: the cutover checker accepted a failing embedded boundary audit" >&2
    exit 1
fi

# The lock is authoritative and must be well formed.
write_lock "someone/else"
expect_external_failure "an embedded lock that names another repository"
write_lock
run_checker_with_external >/dev/null

# Without the embedded boundary audit, the fallback scan must still reject the
# old monorepo layout and copied Core source.
rm -f "$external/Tools/check-invariants.sh"
git -C "$external" init -q
git -C "$external" add -A
run_checker_with_external >/dev/null

printf '%s\n' 'cd ../../../axoloty' > "$external/Tools/old.sh"
git -C "$external" add -A
expect_external_failure "a parent-directory escape"
rm -f "$external/Tools/old.sh"

printf '%s\n' 'scan .build/checkouts' > "$external/Tools/scrape.sh"
git -C "$external" add -A
expect_external_failure "a Core .build scrape"
rm -f "$external/Tools/scrape.sh"

mkdir -p "$external/AxolotyWire/Sources/AxolotyWire"
printf '%s\n' 'struct CopiedCore {}' > "$external/AxolotyWire/Sources/AxolotyWire/Copied.swift"
git -C "$external" add -A
expect_external_failure "a copied Core module directory"
rm -rf "$external/AxolotyWire"

printf '%s\n' 'struct CoreOnlyFixture {}' > "$external/Tools/CoreOnlyFixture.swift"
git -C "$external" add -A
expect_external_failure "a copied Core source filename"
rm -f "$external/Tools/CoreOnlyFixture.swift"
git -C "$external" add -A
run_checker_with_external >/dev/null

# Evidence and release records must pin the locked Core revision.
mkdir -p "$external/docs/evidence"
cat > "$external/docs/evidence/firmware-build.json" <<'JSON'
{"schemaVersion": 1, "coreRevision": "2222222222222222222222222222222222222222"}
JSON
git -C "$external" add -A
expect_external_failure "evidence recorded against another Core revision"
cat > "$external/docs/evidence/firmware-build.json" <<'JSON'
{"schemaVersion": 1, "coreRevision": "1111111111111111111111111111111111111111"}
JSON
git -C "$external" add -A
run_checker_with_external >/dev/null

if AXOLOTY_EXPECTED_CORE_REVISION="3333333333333333333333333333333333333333" \
    AXOLOTY_EMBEDDED_COMPARE_DIR="$external" \
    "$core/Tests/Support/checks/check-embedded-cutover.sh" >/dev/null 2>&1; then
    echo "error: the cutover checker accepted an unexpected locked revision" >&2
    exit 1
fi

echo "embedded cutover checker self-test passed"
