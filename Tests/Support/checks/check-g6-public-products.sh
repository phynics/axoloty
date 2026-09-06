#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Derive the public product inventory from SwiftPM. Building is opt-in for
# ordinary source checks. The release checkpoint opts into the complete
# debug/release build matrix through AXOLOTY_G6_PRODUCT_BUILD=1. This keeps
# CI inventory validation cheap while retaining an explicit, reproducible
# build matrix for offline release evidence.

set -eu

root=${AXOLOTY_G6_PRODUCT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)}
validator="$root/Tests/Support/evidence/validate-g6-products.mjs"
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

# axoloty-tool/ax are products of the Tools harness package; axoloty-inspect/
# axoloty-mcp are products of the Apps application package. Neither is a
# product of the root library package, so each needs its own package-path
# build before it can be smoke-tested.
for spec in "Tools:axoloty-tool" "Tools:ax" "Apps:axoloty-inspect" "Apps:axoloty-mcp"; do
    package_path=${spec%%:*}
    executable=${spec#*:}
    for configuration in debug release; do
        log="${TMPDIR:-/tmp}/axoloty-g6-product-${configuration}-${executable}.log"
        if ! (cd "$root" && swift build --disable-automatic-resolution --package-path "$package_path" --configuration "$configuration" --product "$executable") >"$log" 2>&1; then
            cat "$log" >&2
            exit 1
        fi
    done
    log="${TMPDIR:-/tmp}/axoloty-g6-product-smoke-${executable}.log"
    if ! (cd "$root" && swift run --disable-automatic-resolution --package-path "$package_path" --skip-build "$executable" --help) >"$log" 2>&1; then
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
