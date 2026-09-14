#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Prepare the Core consumer manifest and verify that this firmware checkout
# does not reach into Core's test or build support. This is the only wrapper
# that calls axoloty-tool. ESP-IDF never performs Core preparation itself.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
build_dir=${EMBEDDED_BUILD_DIR:-"/workspace/.build/external-firmware/$proof_run_id"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$build_dir/evidence"}
manifest_input=${1:-"$evidence_dir/consumer-preparation.json"}

if [ -z "${AXOLOTY_SOURCE_DIR:-}" ]; then
    echo "error: AXOLOTY_SOURCE_DIR must select the Core checkout" >&2
    exit 64
fi
core_dir=$(realpath -e -- "$AXOLOTY_SOURCE_DIR" 2>/dev/null || true)
if [ -z "$core_dir" ] || [ ! -d "$core_dir" ]; then
    echo "error: AXOLOTY_SOURCE_DIR is not an existing directory: $AXOLOTY_SOURCE_DIR" >&2
    exit 64
fi
firmware_dir=$(realpath -e -- "$project_dir")
case "$firmware_dir/" in
    "$core_dir/"*|"$core_dir")
        echo "error: firmware checkout must be outside the Core checkout" >&2
        exit 64
        ;;
esac
case "$core_dir/" in
    "$firmware_dir/"*|"$firmware_dir")
        echo "error: Core checkout must be outside the firmware checkout" >&2
        exit 64
        ;;
esac

for required in "$project_dir/CMakeLists.txt" "$project_dir/main/CMakeLists.txt" \
    "$project_dir/components"; do
    if [ ! -e "$required" ]; then
        echo "error: external firmware is missing $required" >&2
        exit 1
    fi
done

# The firmware may use its own tools, but the source tree must not name Core's
# private tests, resolver scripts, or root build. Excluding this tools folder
# keeps the audit rule out of its own result. The generated clean-room record
# names that exclusion.
if command -v rg >/dev/null 2>&1; then
    if rg -n --hidden --glob '!.git/**' --glob '!tools/**' \
        'Packages/|\.build/|Tests/Support|resolve-embedded-core|prepare-embedded-core' \
        "$project_dir"; then
        echo "error: firmware source contains an unsupported Core or private support reference" >&2
        exit 1
    fi
else
    echo "error: rg is required for the firmware clean-room check" >&2
    exit 69
fi

mkdir -p "$evidence_dir"
manifest_dir=$(CDPATH= cd -- "$(dirname -- "$manifest_input")" && pwd)
manifest="$manifest_dir/$(basename -- "$manifest_input")"
clean_room="$evidence_dir/clean-room.json"
tool=${AXOLOTY_TOOL:-}
if [ -z "$tool" ]; then
    tool=$(command -v axoloty-tool 2>/dev/null || true)
fi
if [ -z "$tool" ] && [ -x /opt/axoloty/bin/axoloty-tool ]; then
    tool=/opt/axoloty/bin/axoloty-tool
fi
if [ -z "$tool" ] || [ ! -x "$tool" ]; then
    echo "error: axoloty-tool is unavailable; run this wrapper in the pinned dev image" >&2
    exit 69
fi

mkdir -p "$(dirname -- "$manifest")"
"$tool" embedded consumer prepare \
    --scratch "$build_dir/core-tools" \
    --output "$manifest" > "$evidence_dir/consumer-preparation.stdout"

MANIFEST="$manifest" CORE_DIR="$core_dir" FIRMWARE_DIR="$firmware_dir" \
    PROOF_RUN_ID="$proof_run_id" CLEAN_ROOM="$clean_room" node --input-type=module <<'JS'
import fs from "node:fs";

const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
if (manifest.schemaVersion !== 1 || manifest.status !== "prepared") {
  throw new Error("the Core preparation report is not a supported prepared manifest");
}
if (manifest.core?.sourceDir !== process.env.CORE_DIR) {
  throw new Error("the preparation report selected a different Core checkout");
}
const relative = (root, candidate) => {
  const prefix = `${root}/`;
  if (candidate !== root && !candidate.startsWith(prefix)) {
    throw new Error(`path escapes its declared root: ${candidate}`);
  }
};
for (const packageInfo of manifest.portablePackages ?? []) relative(process.env.CORE_DIR, packageInfo.sourcePath);
relative(manifest.staticRuntimeMacro.scratchDir, manifest.staticRuntimeMacro.executable);
relative(manifest.staticRuntimeMacro.scratchDir, manifest.jsonCore.sourceDir);

const record = {
  schemaVersion: 1,
  status: "passed",
  coreRoot: process.env.CORE_DIR,
  firmwareRoot: process.env.FIRMWARE_DIR,
  sourceCopied: false,
  proofRunId: process.env.PROOF_RUN_ID,
  privateReferenceScan: "passed",
  privateReferenceScanExcluded: "tools/**",
  manifest: process.env.MANIFEST,
};
const temporary = `${process.env.CLEAN_ROOM}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.CLEAN_ROOM);
JS

echo "External firmware validation passed"
echo "  firmware: $firmware_dir"
echo "  Core: $core_dir"
echo "  manifest: $manifest"
echo "  clean-room evidence: $clean_room"
