#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build, flash, and monitor the ESP32-C6 Embedded Swift image (issue #321).
#
# Runs inside the $(IMAGE)-embedded container. Sources ESP-IDF, sets the
# target, builds, flashes, then captures serial output for up to 30 seconds
# looking for the AXOLOTY_SMOKE_OK marker emitted by Main.swift.
#
# Writes a monitor log and structured result to EMBEDDED_OUTPUT_DIR. The Make
# target mirrors both files into the durable .testing/embedded directory.

set -eu

device=${EMBEDDED_DEVICE:-/dev/ttyACM0}
out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
smoke_log="$out_dir/swift-smoke-log.txt"
result_file="$out_dir/swift-smoke-result.json"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}"
build_dir="${EMBEDDED_BUILD_DIR:-$project_dir/build}"
marker="AXOLOTY_SMOKE_OK"
deadline=30
skip_build=${EMBEDDED_SKIP_BUILD:-0}
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -e "$device" ]; then
    echo "SMOKE FAIL: $device does not exist (check CONTAINER_DEVICES)" >&2
    exit 1
fi

. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"
cd "$project_dir"

if [ "$skip_build" = "0" ]; then
    echo "== set-target =="
    idf.py -B "$build_dir" set-target esp32c6
    echo "== build =="
    idf.py -B "$build_dir" build
fi

echo "== flash =="
if [ "$skip_build" = "1" ]; then
    if [ ! -f "$build_dir/flash_args" ]; then
        echo "SMOKE FAIL: flash-only build metadata missing: $build_dir/flash_args" >&2
        exit 1
    fi
    (
        cd "$build_dir"
        "$IDF_PATH/components/esptool_py/esptool/esptool.py" \
            --chip esp32c6 --port "$device" \
            --before default_reset --after hard_reset \
            write_flash @flash_args
    )
else
    idf.py -B "$build_dir" -p "$device" flash
fi

echo "== monitor (deadline ${deadline}s, marker: ${marker}) =="
SERIAL_TOOLS="$support_dir/serial-tools.mjs" node --input-type=module - "$device" "$deadline" "$marker" "$smoke_log" "$result_file" <<'JS'
import fs from "node:fs"; const { captureSerial } = await import(process.env.SERIAL_TOOLS);
const [device,deadline,marker,log,result]=process.argv.slice(2); let found=false,fatal=null;
try { const lines=await captureSerial(device,Number(deadline),line=>{console.log(line);if(["Guru Meditation","abort()","Backtrace:"].some(x=>line.includes(x))){fatal=line;return true;}if(line===marker){found=true;return true;}return false;}); fs.writeFileSync(log,lines.join("\n")+"\n"); fs.writeFileSync(result,JSON.stringify({device,marker,found,fatalLine:fatal,deadlineSeconds:Number(deadline),linesCaptured:lines.length},null,2)+"\n"); } catch(error) { console.error(`SMOKE FAIL: cannot open ${device}: ${error.message}`); process.exit(1); }
if(found&&!fatal){console.log("SMOKE OK");}else{console.error(`SMOKE FAIL: marker not found within ${deadline}s`);process.exit(1);}
JS
