#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Verify the ESP32-C6 Embedded Swift firmware is bit-for-bit reproducible.
#
# Builds Embedded/swift twice from clean, records the SHA-256 of the
# resulting app binary, and compares the two hashes. sdkconfig.defaults
# enables CONFIG_APP_REPRODUCIBLE_BUILD=y so the build omits
# non-deterministic inputs (build timestamps, absolute paths).
#
# Writes both hashes and the comparison to
# .testing/embedded/swift-reproducible-build.json.

set -eu

out_dir="${EMBEDDED_OUTPUT_DIR:-/workspace/.testing/embedded}"
report="$out_dir/swift-reproducible-build.json"
project_dir="${EMBEDDED_PROJECT_DIR:-/workspace/Embedded/swift}"
bin_name="axoloty-swift.bin"
build_dir="${EMBEDDED_BUILD_DIR:-/workspace/.build/embedded-swift-reproducible}"
sdkconfig="$build_dir/sdkconfig"
support_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC=1 . "$support_dir/prepare-embedded-core-tools.sh"

# Validate the caller-selected directory before either build preparation or
# the clean-build rm. A reproducible build owns a dedicated directory whose
# name makes accidental broad-path deletion impossible. Existing directories
# must be real directories, not symlinks; their parent must already exist.
AXOLOTY_EMBEDDED_CORE_NO_EXEC=1 . "$support_dir/resolve-embedded-core.sh"
embedded_core_resolve
project_dir=$(realpath -e -- "$project_dir" 2>/dev/null) || {
    echo "REPRODUCIBLE BUILD FAIL: embedded project directory does not exist: $project_dir" >&2
    exit 1
}
[ -d "$project_dir" ] || {
    echo "REPRODUCIBLE BUILD FAIL: embedded project path is not a directory: $project_dir" >&2
    exit 1
}

validate_reproducible_build_dir() {
    candidate=$1
    case "$candidate" in
        /*) ;;
        *) echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR must be absolute: $candidate" >&2; return 1 ;;
    esac
    case "$candidate" in
        /) echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR is too broad: $candidate" >&2; return 1 ;;
        */) candidate=${candidate%/} ;;
    esac
    case "$candidate" in
        "$project_dir"|"$AXOLOTY_SOURCE_DIR"|"$project_dir"/*)
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR cannot be the project or Core tree: $candidate" >&2
            return 1
            ;;
    esac
    basename=${candidate##*/}
    case "$basename" in
        embedded-swift-reproducible|embedded-swift-reproducible-*) ;;
        *)
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR must be a dedicated embedded-swift-reproducible directory: $candidate" >&2
            return 1
            ;;
    esac
    case "$candidate" in
        "$AXOLOTY_SOURCE_DIR"/*)
            source_relative=${candidate#"$AXOLOTY_SOURCE_DIR/"}
            case "$source_relative" in
                .build/embedded-swift-reproducible|.build/embedded-swift-reproducible-*) ;;
                *)
                    echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR is inside Core outside its dedicated build area: $candidate" >&2
                    return 1
                    ;;
            esac
            ;;
    esac
    parent=${candidate%/*}
    [ -n "$parent" ] || parent=/
    parent_real=$(realpath -e -- "$parent" 2>/dev/null) || {
        echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR parent does not exist: $parent" >&2
        return 1
    }
    case "$parent_real" in
        /|/home|/tmp|/workspace)
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR parent is too broad: $parent_real" >&2
            return 1
            ;;
    esac
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        [ -d "$candidate" ] || {
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR is not a directory: $candidate" >&2
            return 1
        }
        candidate_real=$(realpath -e -- "$candidate" 2>/dev/null) || {
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR cannot be canonicalized: $candidate" >&2
            return 1
        }
        [ "$candidate_real" = "$candidate" ] || {
            echo "REPRODUCIBLE BUILD FAIL: EMBEDDED_BUILD_DIR must not be a symlink: $candidate" >&2
            return 1
        }
    fi
    build_dir=$candidate
}

validate_reproducible_build_dir "$build_dir"
embedded_core_prepare_tools "$build_dir" "$support_dir/resolve-embedded-core.sh"
bin_path="$build_dir/$bin_name"

# Source ESP-IDF for idf.py.
. "${IDF_PATH:-/opt/esp/idf}/export.sh" >/dev/null 2>&1
. "$support_dir/embedded-build-cache.sh"

mkdir -p "$out_dir"
cd "$project_dir"

sha_for_clean_build() {
    rm -rf -- "$build_dir"
    axoloty_prepare_esp_idf_build "$build_dir" esp32c6 1 reproducible \
        -D SDKCONFIG="$sdkconfig" >/dev/null 2>&1
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build >/dev/null 2>&1
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
