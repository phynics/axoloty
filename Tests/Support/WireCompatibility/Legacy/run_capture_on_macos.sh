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
: "${OUTPUT_DIR:?Set OUTPUT_DIR to an empty artifact directory}"
: "${LEGACY_VERSION:=2.4.0}"
: "${LEGACY_SOURCE_COMMIT:=20a97b29832758fb771ac79fd5f7ae36cff69403}"
: "${CAPTURE_READY_TIMEOUT:=10}"
: "${LEGACY_SCENARIO_TIMEOUT_SECONDS:=60}"
: "${LEGACY_TERM_GRACE_SECONDS:=5}"
: "${LEGACY_KILL_GRACE_SECONDS:=2}"

case "$CAPTURE_READY_TIMEOUT" in
  ''|*[!0-9]*)
    echo "CAPTURE_READY_TIMEOUT must be a positive whole number of seconds" >&2
    exit 2
    ;;
  0)
    echo "CAPTURE_READY_TIMEOUT must be a positive whole number of seconds" >&2
    exit 2
    ;;
esac

for timeout_value in "$LEGACY_SCENARIO_TIMEOUT_SECONDS" "$LEGACY_TERM_GRACE_SECONDS" "$LEGACY_KILL_GRACE_SECONDS"; do
  case "$timeout_value" in
    ''|*[!0-9]*) echo "legacy timeout values must be non-negative integers" >&2; exit 2 ;;
  esac
done

case "$SCENARIO" in
  advertise) DEFAULT_EXPECTED_PUBLICATIONS=2 ;;
  deadvertise) DEFAULT_EXPECTED_PUBLICATIONS=2 ;;
  discover-resolve) DEFAULT_EXPECTED_PUBLICATIONS=4 ;;
  *)
    echo "Unsupported legacy scenario: $SCENARIO (expected advertise, deadvertise, or discover-resolve)" >&2
    exit 2
    ;;
esac
: "${EXPECTED_PUBLICATIONS:=$DEFAULT_EXPECTED_PUBLICATIONS}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/process-lifecycle.sh"
SCENARIO_DEADLINE_MS=$(( $(legacy_monotonic_ms) + LEGACY_SCENARIO_TIMEOUT_SECONDS * 1000 ))
CAPTURE_TOOL="$SCRIPT_DIR/../tool/dist/index.js"
CAPTURE="$OUTPUT_DIR/$SCENARIO.jsonl"
MANIFEST="$OUTPUT_DIR/$SCENARIO.manifest.json"
CAPTURE_READY="$OUTPUT_DIR/$SCENARIO.capture-ready"
CAPTURE_LOG="$OUTPUT_DIR/$SCENARIO.capture.log"
SCENARIO_LOG="$OUTPUT_DIR/$SCENARIO.legacy.log"

mkdir -p "$OUTPUT_DIR"
if [ ! -f "$CAPTURE_TOOL" ]; then
  echo "Missing wire CLI at $CAPTURE_TOOL; run 'make wire-tool' first" >&2
  exit 2
fi
if [ -e "$CAPTURE" ] || [ -e "$MANIFEST" ] || [ -e "$CAPTURE_READY" ]; then
  echo "Refusing to overwrite capture artifacts in $OUTPUT_DIR" >&2
  exit 2
fi

node "$CAPTURE_TOOL" capture 'coaty/#' "$CAPTURE" \
  --host "$BROKER_HOST" --port "$BROKER_PORT" \
  --producer coatyswift-legacy --producer-version "$LEGACY_VERSION" \
  --scenario "$SCENARIO" --count "$EXPECTED_PUBLICATIONS" \
  --ready-file "$CAPTURE_READY" >"$CAPTURE_LOG" 2>&1 &
CAPTURE_PID=$!
cleanup() {
  legacy_cleanup_pid "${SCENARIO_PID:-}"
  legacy_cleanup_pid "${CAPTURE_PID:-}"
  rm -f "$CAPTURE_READY"
}
trap cleanup EXIT INT TERM

CAPTURE_READY_DEADLINE=$(( $(legacy_monotonic_ms) + CAPTURE_READY_TIMEOUT * 1000 ))
while [ ! -f "$CAPTURE_READY" ]; do
  if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
    legacy_wait_for_exit "$CAPTURE_PID" 1 "capture probe" || true
    echo "Capture probe exited before subscribing to coaty/#" >&2
    exit 2
  fi
  if [ "$(legacy_monotonic_ms)" -ge "$CAPTURE_READY_DEADLINE" ]; then
    echo "Capture probe did not become ready within $CAPTURE_READY_TIMEOUT seconds" >&2
    exit 2
  fi
  sleep 0.1
done

# The driver must checkout/verify LEGACY_SOURCE_COMMIT itself and publish only
# after its MQTT connection is ready. Arguments form the stable runner contract.
"$LEGACY_SCENARIO_COMMAND" \
  --broker-host "$BROKER_HOST" --broker-port "$BROKER_PORT" \
  --scenario "$SCENARIO" --source-commit "$LEGACY_SOURCE_COMMIT" >"$SCENARIO_LOG" 2>&1 &
SCENARIO_PID=$!
scenario_status=0
legacy_wait_for_exit_until "$SCENARIO_PID" "$SCENARIO_DEADLINE_MS" "legacy scenario" "$LEGACY_SCENARIO_TIMEOUT_SECONDS" || scenario_status=$?
if [ "$scenario_status" -ne 0 ]; then
  cat "$SCENARIO_LOG" >&2 || true
  exit "$scenario_status"
fi

capture_status=0
legacy_wait_for_exit_until "$CAPTURE_PID" "$SCENARIO_DEADLINE_MS" "capture probe" "$LEGACY_SCENARIO_TIMEOUT_SECONDS" || capture_status=$?
if [ "$capture_status" -ne 0 ]; then
  cat "$CAPTURE_LOG" >&2 || true
  exit "$capture_status"
fi
rm -f "$CAPTURE_READY"
trap - EXIT INT TERM

node "$SCRIPT_DIR/../tool/dist/index.js" legacy-manifest "$CAPTURE" "$MANIFEST" \
  --version "$LEGACY_VERSION" --source-commit "$LEGACY_SOURCE_COMMIT" --scenario "$SCENARIO"
