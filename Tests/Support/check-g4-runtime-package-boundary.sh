#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Enforce the package boundary for the replacement runtime. G4 is not open on
# every branch yet, so the checker is explicitly deferred until both runtime
# package roots exist. Once they exist, legacy lifecycle and transport symbols
# are rejected from the replacement sources.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
runtime=${AXOLOTY_G4_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyRuntime}
static=${AXOLOTY_G4_STATIC_RUNTIME_PACKAGE_DIR:-$root/Packages/AxolotyStaticRuntime}

fail() {
    echo "error: $*" >&2
    exit 1
}

if [ ! -d "$runtime" ] && [ ! -d "$static" ]; then
    echo "G4 runtime package boundary deferred: replacement runtime roots are not present"
    exit 0
fi

[ -d "$runtime" ] || fail "replacement host runtime package is missing: $runtime"
[ -d "$static" ] || fail "replacement static runtime package is missing: $static"
[ -f "$runtime/Package.swift" ] || fail "replacement host runtime manifest is missing: $runtime/Package.swift"
[ -f "$static/Package.swift" ] || fail "replacement static runtime manifest is missing: $static/Package.swift"

sources=$(find "$runtime/Sources" "$static/Sources" -type f -name '*.swift' -print 2>/dev/null || true)
[ -n "$sources" ] || fail "replacement runtime packages have no Swift sources"

for source in $sources; do
    if grep -Eq '\b(Container|Controller|CommunicationManager|MQTTNIOClient|PayloadCoder)\b' "$source"; then
        fail "legacy runtime or protocol encoder symbol in replacement source: $source"
    fi
done

echo "G4 replacement runtime package boundary passed"
