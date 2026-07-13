#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

PIN=20a97b29832758fb771ac79fd5f7ae36cff69403
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESOLVED="$SCRIPT_DIR/Package.resolved"

if [ ! -f "$RESOLVED" ]; then
  echo "Missing committed Package.resolved." >&2
  exit 2
fi
python3 - "$RESOLVED" "$PIN" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    resolved = json.load(stream)
pins = resolved.get("object", {}).get("pins", resolved.get("pins", []))
coaty = next((pin for pin in pins if pin.get("package", pin.get("identity", "")).lower() == "coatyswift"), None)
if coaty is None or coaty.get("state", {}).get("revision") != sys.argv[2]:
    raise SystemExit("Package.resolved does not contain the required CoatySwift revision")
PY
