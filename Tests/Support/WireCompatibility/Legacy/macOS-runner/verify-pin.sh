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
node --input-type=module - "$RESOLVED" "$PIN" <<'JS'
import fs from "node:fs";
const resolved=JSON.parse(fs.readFileSync(process.argv[2])), pins=resolved.object?.pins ?? resolved.pins ?? [], coaty=pins.find(pin=>(pin.package??pin.identity??"").toLowerCase()==="coatyswift");
if(!coaty || coaty.state?.revision!==process.argv[3]) throw new Error("Package.resolved does not contain the required CoatySwift revision");
JS
