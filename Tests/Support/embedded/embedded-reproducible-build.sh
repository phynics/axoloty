#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Verify the ESP32-C6 smoke firmware is bit-for-bit reproducible.
#
# Runs inside the $(IMAGE)-embedded container (see the Makefile
# `embedded-reproducible-build` target). Builds Embedded/ twice from clean,
# records the SHA-256 of the resulting app binary, and compares the two
# hashes. sdkconfig.defaults enables CONFIG_APP_REPRODUCIBLE_BUILD=y so the
# build omits non-deterministic inputs (build timestamps, absolute paths).
#
# Writes both hashes and the comparison to
# .testing/embedded/reproducible-build.json.

set -eu

out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
report="$out_dir/reproducible-build.json"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded}"
bin_name="axoloty-smoke.bin"
# idf.py places the app image under build/<project>.bin relative to the
# project root.
bin_path="$project_dir/build/$bin_name"

# Source ESP-IDF for idf.py.
# shellcheck source=/dev/null
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1

mkdir -p "$out_dir"

cd "$project_dir"

sha_for_clean_build() {
    idf.py fullclean >/dev/null 2>&1
    idf.py build >/dev/null 2>&1
    if [ ! -f "$bin_path" ]; then
        echo "REPRODUCIBLE BUILD FAIL: $bin_path not produced" >&2
        exit 1
    fi
    sha256sum "$bin_path" | awk '{print $1}'
}

echo "== build 1 =="
hash1=$(sha_for_clean_build)
echo "hash1: $hash1"

echo "== build 2 =="
hash2=$(sha_for_clean_build)
echo "hash2: $hash2"

if [ "$hash1" = "$hash2" ]; then
    result="REPRODUCIBLE BUILD OK"
    status=true
else
    result="REPRODUCIBLE BUILD FAIL"
    status=false
fi

cat >"$report" <<EOF
{
  "binary": "${bin_name}",
  "hash1": "${hash1}",
  "hash2": "${hash2}",
  "reproducible": ${status},
  "capturedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "$result"
if [ "$status" = "false" ]; then
    exit 1
fi
