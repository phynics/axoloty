#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validate the two-repository embedded cutover from the Core side.
#
# This repository owns the portable protocol and runtime implementation and
# proves it stays Embedded-Swift compatible without a firmware checkout. The
# required canonical plan must therefore stay firmware-free and hardware-free,
# the published consumer contract must expose only portable Core paths, and
# AXOLOTY_SOURCE_DIR must remain the only documented local Core override.
#
# When an axoloty-embedded checkout is supplied through
# AXOLOTY_EMBEDDED_COMPARE_DIR, the check also audits it for old-monorepo
# dependence and copied Core source. It delegates to that repository's own
# boundary audit with this Core checkout as the comparison root, then verifies
# that the embedded lock, evidence records, and release certificates pin one
# Core revision.
#
# The check never builds, flashes, probes hardware, uses a broker, or requires
# a firmware checkout. Ordinary Core verification runs it unchanged.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)

fail() {
    echo "EMBEDDED CUTOVER FAIL: $*" >&2
    exit 1
}

manifest=${AXOLOTY_CUTOVER_MANIFEST:-$root/Tests/Support/test-tiers.json}
contract=${AXOLOTY_CUTOVER_CONTRACT:-$root/docs/embedded-consumer-contract.json}
contract_doc=${AXOLOTY_CUTOVER_CONTRACT_DOC:-$root/docs/embedded-consumer-contract.md}

command -v node >/dev/null 2>&1 || fail "node is required to read the repository manifests"
test -f "$manifest" || fail "canonical test manifest is missing: $manifest"
test -f "$contract" || fail "embedded consumer contract is missing: $contract"
test -f "$contract_doc" || fail "embedded consumer contract document is missing: $contract_doc"

# 1. The contract exposes only repository-relative portable Core paths.
node - "$contract" "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [contractPath, root] = process.argv.slice(2);
const fail = message => {
  console.error(`EMBEDDED CUTOVER FAIL: ${message}`);
  process.exit(1);
};
let contract;
try {
  contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
} catch (error) {
  fail(`embedded consumer contract is not readable JSON: ${error.message}`);
}
if (contract.schemaVersion !== 1) fail("embedded consumer contract schemaVersion must be 1");
const packages = contract.portablePackages;
if (!Array.isArray(packages) || packages.length === 0) {
  fail("embedded consumer contract declares no portable packages");
}
const relativePath = (value, label) => {
  if (typeof value !== "string" || value.length === 0) fail(`${label} is missing`);
  if (path.isAbsolute(value) || value.split("/").includes("..")) {
    fail(`${label} must stay inside the checkout: ${value}`);
  }
  if (/^(?:\.build|Tests|Embedded)(?:\/|$)/.test(value)) fail(`${label} names a private path: ${value}`);
  const resolved = path.resolve(root, value);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    fail(`${label} resolves outside the checkout: ${value}`);
  }
  return resolved;
};
for (const entry of packages) {
  const name = entry.package ?? entry.name ?? "<unnamed>";
  relativePath(entry.packagePath, `${name}.packagePath`);
  const source = relativePath(entry.sourcePath, `${name}.sourcePath`);
  if (!fs.existsSync(source) || !fs.statSync(source).isDirectory()) {
    fail(`${name}.sourcePath is not a directory: ${entry.sourcePath}`);
  }
}
const lockPath = contract.jsonCore?.lockPath;
const resolvedLock = relativePath(lockPath, "jsonCore.lockPath");
if (!fs.existsSync(resolvedLock)) fail(`jsonCore.lockPath is missing on disk: ${lockPath}`);
NODE

# 2. AXOLOTY_SOURCE_DIR is the only documented local Core override.
grep -q 'AXOLOTY_SOURCE_DIR' "$contract_doc" \
    || fail "$contract_doc does not document AXOLOTY_SOURCE_DIR"
for alternative in AXOLOTY_CORE_DIR AXOLOTY_CORE_SOURCE_DIR AXOLOTY_CHECKOUT_DIR EMBEDDED_CORE_DIR; do
    if grep -q "$alternative" "$contract_doc"; then
        fail "$contract_doc documents $alternative; AXOLOTY_SOURCE_DIR is the only local override"
    fi
done

# 3. The required canonical plan is firmware-free and hardware-free.
node - "$manifest" <<'NODE'
const fs = require("node:fs");
const [manifestPath] = process.argv.slice(2);
const fail = message => {
  console.error(`EMBEDDED CUTOVER FAIL: ${message}`);
  process.exit(1);
};
let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch (error) {
  fail(`canonical test manifest is not readable JSON: ${error.message}`);
}
if (manifest.schemaVersion !== 2) fail("canonical test manifest schemaVersion must be 2");
const nodes = new Map((manifest.nodes ?? []).map(node => [node.id, node]));
const gates = manifest.requiredGates;
if (!Array.isArray(gates) || gates.length === 0) {
  fail("canonical test manifest declares no required gates");
}
// Firmware-owned paths and device environment. A required gate that names one
// reintroduces a dependency on the firmware working tree or on hardware.
const firmwareTokens = [
  "Embedded/",
  "Tests/Support/embedded/",
  "EMBEDDED_PROJECT_DIR",
  "EMBEDDED_DEVICE",
  "AXOLOTY_WIFI_SSID",
  ".build/embedded",
];
for (const id of gates) {
  const node = nodes.get(id);
  if (!node) fail(`required gate ${id} is not a declared node`);
  if (node.hardware !== "forbidden") fail(`${id}: required gates must declare hardware forbidden`);
  if ((node.resources ?? []).includes("embedded-device")) {
    fail(`${id}: required gates must not own an embedded-device resource`);
  }
  const command = [node.command?.executable ?? "", ...(node.command?.arguments ?? [])].join(" ");
  for (const token of firmwareTokens) {
    if (command.includes(token)) fail(`${id}: required gate references firmware-owned path ${token}`);
  }
}
const consumer = nodes.get("embedded-core-consumer");
if (!consumer || !gates.includes("embedded-core-consumer")) {
  fail("required gates must keep the firmware-free embedded-core-consumer node");
}
const consumerCommand = [consumer.command?.executable ?? "", ...(consumer.command?.arguments ?? [])].join(" ");
if (!consumerCommand.includes("Tests/Support/checks/check-embedded-swift-core.sh")) {
  fail("embedded-core-consumer must run the firmware-free Core consumer check");
}
NODE

# 4. Audit an external axoloty-embedded checkout when one is supplied.
if [ -n "${AXOLOTY_EMBEDDED_COMPARE_DIR:-}" ]; then
    external=$(CDPATH= cd -- "$AXOLOTY_EMBEDDED_COMPARE_DIR" 2>/dev/null && pwd -P) \
        || fail "AXOLOTY_EMBEDDED_COMPARE_DIR is not a directory: $AXOLOTY_EMBEDDED_COMPARE_DIR"
    test -f "$external/axoloty-core.lock.json" \
        || fail "the embedded checkout has no axoloty-core.lock.json: $external"

    lock_revision=$(node - "$external/axoloty-core.lock.json" <<'NODE'
const fs = require("node:fs");
const [lockPath] = process.argv.slice(2);
const fail = message => {
  console.error(`EMBEDDED CUTOVER FAIL: ${message}`);
  process.exit(1);
};
let lock;
try {
  lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
} catch (error) {
  fail(`axoloty-core.lock.json is not readable JSON: ${error.message}`);
}
if (lock.schemaVersion !== 1) fail("axoloty-core.lock.json schemaVersion must be 1");
const core = lock.core ?? {};
if (core.identity !== "phynics/axoloty") {
  fail(`axoloty-core.lock.json identity must be phynics/axoloty, found ${core.identity}`);
}
if (core.revisionFormat !== "git-commit-sha1") fail("axoloty-core.lock.json revisionFormat must be git-commit-sha1");
if (!/^[0-9a-f]{40}$/.test(core.revision ?? "")) {
  fail("axoloty-core.lock.json revision must be a full 40-character commit SHA");
}
for (const field of ["url", "version", "consumerContractPath"]) {
  if (!core[field]) fail(`axoloty-core.lock.json core.${field} is required`);
}
process.stdout.write(core.revision);
NODE
)
    if [ -n "${AXOLOTY_EXPECTED_CORE_REVISION:-}" ] \
        && [ "$lock_revision" != "$AXOLOTY_EXPECTED_CORE_REVISION" ]; then
        fail "the embedded checkout locks Core $lock_revision, expected $AXOLOTY_EXPECTED_CORE_REVISION"
    fi

    if [ -f "$external/Tools/check-invariants.sh" ] && command -v bash >/dev/null 2>&1; then
        (cd "$external" && AXOLOTY_CORE_COMPARE_DIR="$root" bash Tools/check-invariants.sh) \
            || fail "the axoloty-embedded boundary audit reported violations"
    else
        # Older firmware checkouts predate the embedded boundary audit. Apply
        # the same escaped-layout and copied-source rules directly.
        node - "$external" "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const [external, coreRoot] = process.argv.slice(2);
const fail = message => {
  console.error(`EMBEDDED CUTOVER FAIL: ${message}`);
  process.exit(1);
};
let tracked;
try {
  tracked = execFileSync("git", ["-C", external, "ls-files"], { encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
} catch {
  fail("the embedded checkout is not a Git work tree, so the fallback boundary scan cannot run");
}
const excluded = /^(?:docs\/|\.github\/|\.testing\/|README\.md$|AGENTS\.md$|Tools\/check-invariants\.sh$)/;
const privateTokens = ["../../../", ".build/checkouts", ".build/debug", "/workspace/Embedded", "Tests/Support"];
for (const file of tracked) {
  if (excluded.test(file)) continue;
  const absolute = path.join(external, file);
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) continue;
  const text = fs.readFileSync(absolute, "utf8");
  if (text.includes("\u0000")) continue;
  for (const token of privateTokens) {
    if (text.includes(token)) fail(`${file} names the old monorepo layout: ${token}`);
  }
}
const modules = [
  "AxolotyWire",
  "AxolotyObjectModel",
  "AxolotyProtocol",
  "AxolotyCoatyModels",
  "AxolotyStaticRuntime",
  "_JSONCore",
];
for (const module of modules) {
  if (tracked.some(file => file.startsWith(`${module}/`) || file.includes(`/${module}/`))) {
    fail(`a directory named ${module}/ holds tracked files; portable Core is compiled in place`);
  }
}
const coreNames = new Set();
for (const module of modules) {
  const directory = path.join(coreRoot, "Packages", module, "Sources", module);
  if (!fs.existsSync(directory)) continue;
  for (const name of fs.readdirSync(directory)) if (name.endsWith(".swift")) coreNames.add(name);
}
for (const file of tracked) {
  if (!file.endsWith(".swift") || path.basename(file) === "Package.swift") continue;
  if (coreNames.has(path.basename(file))) fail(`${file} copies a portable Core source filename`);
  const text = fs.readFileSync(path.join(external, file), "utf8");
  for (const module of modules) {
    if (new RegExp(`\\.(?:target|systemLibrary)\\([^)]*name:\\s*"${module}"`).test(text)) {
      fail(`${file} declares ${module} as a local target`);
    }
  }
}
NODE
    fi

    pinned_records=$(node - "$external" "$lock_revision" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [external, revision] = process.argv.slice(2);
const fail = message => {
  console.error(`EMBEDDED CUTOVER FAIL: ${message}`);
  process.exit(1);
};
const readJson = relative => {
  try {
    return JSON.parse(fs.readFileSync(path.join(external, relative), "utf8"));
  } catch (error) {
    fail(`${relative} is not readable JSON: ${error.message}`);
  }
};
const jsonFiles = relative => {
  const directory = path.join(external, relative);
  return fs.existsSync(directory)
    ? fs.readdirSync(directory).filter(name => name.endsWith(".json")).sort()
    : [];
};
let checked = 0;
for (const name of jsonFiles("docs/evidence")) {
  const record = readJson(path.join("docs/evidence", name));
  if (record.coreRevision === undefined) continue;
  checked += 1;
  if (record.coreRevision !== revision) {
    fail(`docs/evidence/${name} records Core ${record.coreRevision} but the lock is ${revision}`);
  }
}
const releases = path.join(external, "releases");
for (const profile of fs.existsSync(releases) ? fs.readdirSync(releases).sort() : []) {
  if (!fs.statSync(path.join(releases, profile)).isDirectory()) continue;
  for (const name of jsonFiles(path.join("releases", profile))) {
    const record = readJson(path.join("releases", profile, name));
    if (record.axoloty?.sha === undefined) continue;
    checked += 1;
    if (record.axoloty.sha !== revision) {
      fail(`releases/${profile}/${name} certifies Core ${record.axoloty.sha} but the lock is ${revision}`);
    }
  }
}
process.stdout.write(String(checked));
NODE
)
    echo "Embedded checkout audit passed: $external (Core $lock_revision, $pinned_records pinned record(s))"
else
    echo "Embedded checkout audit skipped: set AXOLOTY_EMBEDDED_COMPARE_DIR to audit a firmware checkout"
fi

echo "EMBEDDED CUTOVER OK: contract, required plan, and local override remain firmware-free"
