#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Prepare the Core consumer manifest and verify that this firmware checkout
# does not reach into Core's test or build support. This is the only wrapper
# that calls axoloty-tool. ESP-IDF never performs Core preparation itself.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
proof_root=${EMBEDDED_PROOF_ROOT:-/workspace/.build}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$build_dir/evidence"}
preparation_scratch=${EMBEDDED_PREPARATION_SCRATCH:-"$proof_root/core-tools"}
manifest_input=${1:-"$evidence_dir/preparation.json"}

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

expected_firmware_sha=${AXOLOTY_EXPECTED_FIRMWARE_SHA:-}
if [ -z "$expected_firmware_sha" ] ||
    ! printf '%s' "$expected_firmware_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "error: AXOLOTY_EXPECTED_FIRMWARE_SHA must be the selected 40-character Core SHA" >&2
    exit 64
fi
revision_file="$project_dir/.axoloty-source-revision"
if [ ! -f "$revision_file" ] ||
    [ "$(tr -d '[:space:]' < "$revision_file")" != "$expected_firmware_sha" ]; then
    echo "error: firmware extraction revision differs from the selected Core commit" >&2
    exit 1
fi

# The firmware may use its own tools, but the source tree must not name Core's
# private tests, resolver scripts, or root build. Excluding this tools folder
# keeps the audit rule out of its own result. The generated clean-room record
# names that exclusion.
if command -v rg >/dev/null 2>&1; then
    private_tests_path=$(printf '%s/%s' Tests Support)
    if (cd "$project_dir" && rg -n --hidden --glob '!.git/**' --glob '!tools/**' \
        "Packages/|\\.build/|${private_tests_path}|resolve-embedded-core|prepare-embedded-core" \
        .); then
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
    --scratch "$preparation_scratch" \
    --output "$manifest" > "$evidence_dir/consumer-preparation.stdout"

MANIFEST="$manifest" CORE_DIR="$core_dir" FIRMWARE_DIR="$firmware_dir" \
    PROOF_RUN_ID="$proof_run_id" EXPECTED_SHA="$expected_firmware_sha" \
    PREPARATION_SCRATCH="$preparation_scratch" CLEAN_ROOM="$clean_room" node --input-type=module <<'JS'
import fs from "node:fs";
import path from "node:path";

const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
if (manifest.schemaVersion !== 1 || manifest.status !== "prepared") {
  throw new Error("the Core preparation report is not a supported prepared manifest");
}
if (manifest.core?.sourceDir !== process.env.CORE_DIR) {
  throw new Error("the preparation report selected a different Core checkout");
}
if (manifest.core?.sha !== process.env.EXPECTED_SHA || manifest.core?.dirty !== false) {
  throw new Error("the preparation report is not for the clean selected Core revision");
}
const expectedPackages = ["AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"];
if (!Array.isArray(manifest.portablePackages) || manifest.portablePackages.length !== expectedPackages.length ||
    manifest.portablePackages.some((entry, index) => entry?.name !== expectedPackages[index])) {
  throw new Error("the preparation report portable package order is not supported");
}
const relative = (root, candidate) => {
  if (typeof root !== "string" || typeof candidate !== "string" || !path.isAbsolute(root) || !path.isAbsolute(candidate)) {
    throw new Error("preparation report paths must be absolute");
  }
  const prefix = `${root}/`;
  if (candidate !== root && !candidate.startsWith(prefix)) {
    throw new Error(`path escapes its declared root: ${candidate}`);
  }
};
for (const packageInfo of manifest.portablePackages) relative(process.env.CORE_DIR, packageInfo.sourcePath);
relative(manifest.staticRuntimeMacro.scratchDir, manifest.staticRuntimeMacro.executable);
relative(manifest.staticRuntimeMacro.scratchDir, manifest.jsonCore.sourceDir);
if (manifest.staticRuntimeMacro.scratchDir !== process.env.PREPARATION_SCRATCH) {
  throw new Error("preparation report scratch is not caller-owned proof storage");
}
if (typeof manifest.jsonCore.revision !== "string" || !/^[0-9a-f]{40}$/.test(manifest.jsonCore.revision)) {
  throw new Error("preparation report has an invalid _JSONCore revision");
}

const record = {
  schemaVersion: 1,
  status: "passed",
  coreRoot: process.env.CORE_DIR,
  firmwareRoot: process.env.FIRMWARE_DIR,
  portableSourceCopied: false,
  proofRunId: process.env.PROOF_RUN_ID,
  privateReferenceScan: "passed",
  privateReferenceScanExcluded: "tools/**",
  manifest: process.env.MANIFEST,
};
const temporary = `${process.env.CLEAN_ROOM}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.CLEAN_ROOM);
JS

if [ "${EMBEDDED_VALIDATE_FINAL:-0}" = 1 ]; then
    final_proof="$evidence_dir/go-proof.json"
    if [ ! -f "$final_proof" ]; then
        echo "error: final proof is incomplete; go-proof.json is missing" >&2
        exit 1
    fi
    node --input-type=module - "$final_proof" <<'JS'
import fs from "node:fs";
const proof = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (proof.result !== "passed" || proof.device !== "esp32c6" || proof.smoke?.validation?.passed !== true) {
  throw new Error("go-proof.json does not report a passed ESP32-C6 smoke proof");
}
JS
fi

echo "External firmware validation passed"
echo "  firmware: $firmware_dir"
echo "  Core: $core_dir"
echo "  manifest: $manifest"
echo "  clean-room evidence: $clean_room"
