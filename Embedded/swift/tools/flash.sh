#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Flash a previously built external firmware checkout and validate its serial
# smoke protocol. Device privileges are supplied by the outer container
# runner. This script never invokes sudo or rebuilds the firmware.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
proof_root=${EMBEDDED_PROOF_ROOT:-/workspace/.build}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
manifest="$evidence_dir/preparation.json"
device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
serial_log="$evidence_dir/swift-smoke-log.txt"
smoke_result="$evidence_dir/swift-smoke-result.json"
deadline=${EMBEDDED_DEADLINE:-120}

if [ ! -e "$device" ]; then
    echo "error: serial device is unavailable: $device" >&2
    echo "hint: pass EMBEDDED_DEVICE=/dev/ttyACM0 or use the NixOS sudo command in the manual" >&2
    exit 1
fi

if [ ! -f "$manifest" ] || [ ! -f "$build_dir/flash_args" ] || \
    [ ! -s "$build_dir/axoloty-swift.bin" ] || [ ! -f "$evidence_dir/build-provenance.json" ]; then
    echo "error: proof build metadata or axoloty-swift.bin is missing; run the build target first" >&2
    exit 1
fi

# Never allow a previous attempt's device or GO records to survive a retry.
# The build provenance remains, but every flash-specific record is regenerated
# from the device and artifact used by this invocation.
rm -f "$evidence_dir/device-manifest.json" "$evidence_dir/device-info-raw.txt" \
    "$evidence_dir/flash.log" "$evidence_dir/swift-smoke-log.txt" \
    "$evidence_dir/swift-smoke-result.json" "$evidence_dir/go-proof.json"

idf_root=${IDF_PATH:-/opt/esp/idf}
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1

mkdir -p "$evidence_dir"
set +e
chip_info=$(esptool.py --port "$device" chip_id 2>&1)
chip_status=$?
set -e
printf '%s\n' "$chip_info" > "$evidence_dir/device-info-raw.txt"
if [ "$chip_status" -ne 0 ] || ! printf '%s\n' "$chip_info" | grep -Eiq 'ESP32-C6'; then
    echo "error: selected device is not an ESP32-C6 (see $evidence_dir/device-info-raw.txt)" >&2
    exit 1
fi
node "$script_dir/write-device-manifest.mjs" \
    "$device" "$evidence_dir/device-info-raw.txt" "$evidence_dir/device-manifest.json"

artifact=$(realpath -e -- "$build_dir/axoloty-swift.bin")
artifact_real="$artifact"
node --input-type=module - "$artifact" "$evidence_dir/build-provenance.json" <<'JS'
import crypto from "node:crypto";
import fs from "node:fs";

const [artifactPath, provenancePath] = process.argv.slice(2);
const provenance = JSON.parse(fs.readFileSync(provenancePath, "utf8"));
const actual = crypto.createHash("sha256").update(fs.readFileSync(artifactPath)).digest("hex");
if (provenance.artifact?.path !== artifactPath || provenance.artifact?.sha256 !== actual ||
    provenance.firmwareSha256 !== actual) {
  throw new Error("the built artifact changed after provenance was recorded");
}
JS
artifact_in_flash_args=0
for flash_arg in $(tr '\n' ' ' < "$build_dir/flash_args"); do
    case "$flash_arg" in
        -*|@*) continue ;;
    esac
    if [ -e "$flash_arg" ] && [ "$(realpath -e -- "$flash_arg")" = "$artifact_real" ]; then
        artifact_in_flash_args=1
    elif [ -e "$build_dir/$flash_arg" ] && [ "$(realpath -e -- "$build_dir/$flash_arg")" = "$artifact_real" ]; then
        artifact_in_flash_args=1
    fi
done
if [ "$artifact_in_flash_args" -ne 1 ]; then
    echo "error: flash_args does not reference the built axoloty-swift.bin" >&2
    exit 1
fi
if ! (
    cd "$build_dir"
    python3 "$idf_root/components/esptool_py/esptool/esptool.py" \
        --chip esp32c6 --port "$device" \
        --before default_reset --after no_reset write_flash @flash_args
) > "$evidence_dir/flash.log" 2>&1; then
    cat "$evidence_dir/flash.log" >&2
    echo "error: flashing failed for $device" >&2
    exit 1
fi

echo "== monitor (deadline ${deadline}s, smoke protocol) =="
set +e
if command -v script >/dev/null 2>&1; then
    # idf_monitor requires a TTY on stdin.  `script` supplies a bounded
    # pseudo-terminal while keeping the captured stream file-oriented for the
    # JSONL validator.
    timeout --foreground "$deadline" script -q -e -c \
        "exec idf.py -C '$project_dir' -B '$build_dir' -p '$device' monitor" \
        /dev/null > "$serial_log" 2>&1
    monitor_status=$?
else
    echo "error: the pinned image lacks the 'script' pseudo-terminal helper" >&2
    monitor_status=127
fi
set -e
set +e
node "$script_dir/validate-smoke.mjs" "$serial_log" "$smoke_result" "$device" "$deadline"
validation_status=$?
set -e
if [ "$validation_status" -ne 0 ]; then
    echo "error: embedded-swift-smoke-v2 validation failed (see $smoke_result)" >&2
    exit "$validation_status"
fi
if [ "$monitor_status" -ne 0 ] && [ "$monitor_status" -ne 124 ]; then
    echo "error: ESP-IDF monitor failed with status $monitor_status" >&2
    exit 1
fi
node "$script_dir/write-go-proof.mjs" \
    "$evidence_dir/build-provenance.json" "$smoke_result" \
    "$evidence_dir/device-manifest.json" "$evidence_dir/go-proof.json" "$artifact"
echo "External firmware flash and smoke validation passed: $device"
