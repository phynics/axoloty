#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validate the device-independent ESP-IDF runtime used by embedded builds.

set -eu

idf_path=${IDF_PATH:-/opt/esp/idf}
idf_tools_path=${IDF_TOOLS_PATH:-/opt/esp/tools}

fail() {
    echo "EMBEDDED ENVIRONMENT FAIL: $1" >&2
    exit 1
}

[ -f "$idf_path/export.sh" ] || fail "ESP-IDF export script is missing: $idf_path/export.sh"
[ -d "$idf_tools_path" ] || fail "ESP-IDF tools are missing: $idf_tools_path (check IDF_TOOLS_PATH)"
[ -r "$idf_tools_path" ] || fail "ESP-IDF tools are not readable: $idf_tools_path"

idf_export_log=$(mktemp)
trap 'rm -f "$idf_export_log"' EXIT
set +e
. "$idf_path/export.sh" >"$idf_export_log" 2>&1
idf_export_status=$?
set -e
if [ "$idf_export_status" -ne 0 ]; then
    echo "EMBEDDED ENVIRONMENT FAIL: ESP-IDF activation failed" >&2
    cat "$idf_export_log" >&2
    exit 1
fi
rm -f "$idf_export_log"
trap - EXIT

command -v idf.py >/dev/null 2>&1 || fail "idf.py is unavailable after ESP-IDF activation"
command -v riscv32-esp-elf-gcc >/dev/null 2>&1 || fail "ESP32-C6 GCC is unavailable after ESP-IDF activation"

echo "EMBEDDED ENVIRONMENT OK"
idf.py --version
riscv32-esp-elf-gcc --version | head -n 1
