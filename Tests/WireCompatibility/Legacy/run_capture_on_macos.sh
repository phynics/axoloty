#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "Legacy CoatySwift capture requires macOS; Linux validates committed artifacts only." >&2
  exit 2
fi

: "${LEGACY_SCENARIO_COMMAND:?Set LEGACY_SCENARIO_COMMAND to the pinned legacy scenario executable}"
: "${BROKER_HOST:=127.0.0.1}"
: "${BROKER_PORT:=1883}"
: "${SCENARIO:=advertise}"
: "${EXPECTED_PUBLICATIONS:=1}"
: "${OUTPUT_DIR:?Set OUTPUT_DIR to an empty artifact directory}"
: "${LEGACY_VERSION:=2.4.0}"
: "${LEGACY_SOURCE_COMMIT:=20a97b29832758fb771ac79fd5f7ae36cff69403}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CAPTURE_TOOL="$SCRIPT_DIR/../Capture/mqtt_capture.py"
CAPTURE="$OUTPUT_DIR/$SCENARIO.jsonl"
MANIFEST="$OUTPUT_DIR/$SCENARIO.manifest.json"

mkdir -p "$OUTPUT_DIR"
if [ -e "$CAPTURE" ] || [ -e "$MANIFEST" ]; then
  echo "Refusing to overwrite capture artifacts in $OUTPUT_DIR" >&2
  exit 2
fi

python3 "$CAPTURE_TOOL" \
  --host "$BROKER_HOST" --port "$BROKER_PORT" --topic 'coaty/#' \
  --producer coatyswift-legacy --producer-version "$LEGACY_VERSION" \
  --scenario "$SCENARIO" --count "$EXPECTED_PUBLICATIONS" --output "$CAPTURE" &
CAPTURE_PID=$!
cleanup() {
  kill "$CAPTURE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# The driver must checkout/verify LEGACY_SOURCE_COMMIT itself and publish only
# after its MQTT connection is ready. Arguments form the stable runner contract.
"$LEGACY_SCENARIO_COMMAND" \
  --broker-host "$BROKER_HOST" --broker-port "$BROKER_PORT" \
  --scenario "$SCENARIO" --source-commit "$LEGACY_SOURCE_COMMIT"
wait "$CAPTURE_PID"
trap - EXIT INT TERM

python3 "$SCRIPT_DIR/create_manifest.py" "$CAPTURE" --output "$MANIFEST" \
  --version "$LEGACY_VERSION" --source-commit "$LEGACY_SOURCE_COMMIT" --scenario "$SCENARIO"
python3 "$SCRIPT_DIR/validate_legacy_capture.py" "$CAPTURE" --manifest "$MANIFEST"
