#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Runs the AxolotyZenoh C façade ownership tests under AddressSanitizer and
# UndefinedBehaviorSanitizer. A provisioned prebuilt zenoh-c archive is
# required; see docs/dependencies/zenoh.md. Provisioning unpacks the archive
# and rewrites zenohc.pc's hardcoded prefix, then this script points
# pkg-config and the runtime loader at the unpacked tree.
#
#   AXOLOTY_ZENOH_C_DIR=/path/to/zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone \
#     Packages/AxolotyZenoh/Tests/run-sanitized-tests.sh
#
# UBSan needs an explicit runtime archive on Linux: SwiftPM compiles the C
# target with -fsanitize=undefined but its test-runner link line does not add
# the sanitizer runtime for a clang target.

set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zenoh_dir=${AXOLOTY_ZENOH_C_DIR:-}
[ -n "$zenoh_dir" ] || {
    echo "FAIL: set AXOLOTY_ZENOH_C_DIR to the unpacked zenoh-c archive root" >&2
    exit 1
}
[ -f "$zenoh_dir/lib/pkgconfig/zenohc.pc" ] || {
    echo "FAIL: $zenoh_dir does not contain lib/pkgconfig/zenohc.pc" >&2
    exit 1
}
PKG_CONFIG_PATH="$zenoh_dir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
LD_LIBRARY_PATH="$zenoh_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH LD_LIBRARY_PATH

echo "== AddressSanitizer =="
swift test --package-path "$package_dir" --sanitize=address --disable-xctest

echo "== UndefinedBehaviorSanitizer =="
resource_dir=$(clang -print-resource-dir)
ubsan_runtime="$resource_dir/lib/linux/libclang_rt.ubsan_standalone-$(uname -m).a"
[ -f "$ubsan_runtime" ] || {
    echo "FAIL: UBSan runtime archive not found at $ubsan_runtime" >&2
    exit 1
}
swift test --package-path "$package_dir" --sanitize=undefined --disable-xctest -Xlinker "$ubsan_runtime"
