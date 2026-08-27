#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Derive the public product inventory from SwiftPM. Building is opt-in for
# ordinary source checks and enabled by the release checkpoint through
# AXOLOTY_G6_PRODUCT_BUILD=1. This keeps inventory validation cheap while
# retaining an explicit, reproducible build matrix for release evidence.

set -eu

root=${AXOLOTY_G6_PRODUCT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
validator="$root/Tests/Support/validate-g6-products.mjs"
[ -f "$validator" ] || { echo "G6 PUBLIC PRODUCTS FAIL: validator missing" >&2; exit 1; }

report=$(node "$validator" "$root") || {
    printf '%s\n' "$report" >&2
    exit 1
}
printf '%s\n' "$report"

if [ "${AXOLOTY_G6_PRODUCT_BUILD:-0}" != "1" ]; then
    exit 0
fi

products=$(node -e '
const report = JSON.parse(require("fs").readFileSync(0, "utf8"));
for (const name of [...report.actual.libraries, ...report.actual.executables]) console.log(name);
' <<EOF
$report
EOF
)

for configuration in debug release; do
    for product in $products; do
        log="${TMPDIR:-/tmp}/axoloty-g6-product-${configuration}-${product}.log"
        if ! (cd "$root" && swift build --disable-automatic-resolution --configuration "$configuration" --product "$product") >"$log" 2>&1; then
            cat "$log" >&2
            exit 1
        fi
    done
done

for executable in axoloty-tool ax axoloty-inspect axoloty-mcp; do
    log="${TMPDIR:-/tmp}/axoloty-g6-product-smoke-${executable}.log"
    if ! (cd "$root" && swift run --disable-automatic-resolution --skip-build "$executable" --help) >"$log" 2>&1; then
        cat "$log" >&2
        exit 1
    fi
done

if [ -d "$root/Examples" ]; then
    for configuration in debug release; do
        log="${TMPDIR:-/tmp}/axoloty-g6-example-${configuration}.log"
        if ! (cd "$root" && swift build --disable-automatic-resolution --package-path Examples --configuration "$configuration") >"$log" 2>&1; then
            cat "$log" >&2
            exit 1
        fi
    done
    for example in HostRuntimeExample WireExample; do
        log="${TMPDIR:-/tmp}/axoloty-g6-example-smoke-${example}.log"
        if ! (cd "$root" && swift run --disable-automatic-resolution --package-path Examples --skip-build "$example" --help) >"$log" 2>&1; then
            cat "$log" >&2
            exit 1
        fi
    done
fi

printf '%s\n' '{"buildMode":"debug-release","executableSmoke":"help"}'
