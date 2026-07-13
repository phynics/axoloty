#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/versions.env"

actual_js=$(git ls-remote --tags https://github.com/coatyio/coaty-js.git "refs/tags/v$COATYJS_VERSION^{}" | awk '{print $1}')
actual_swift=$(git ls-remote --tags https://github.com/coatyio/coaty-swift.git "refs/tags/$COATY_SWIFT_LEGACY_VERSION^{}" | awk '{print $1}')
actual_integrity=$(curl -fsSL "https://registry.npmjs.org/@coaty/core/$COATYJS_VERSION" | sed -n 's/.*"integrity":"\([^"]*\)".*/\1/p')

test "$actual_js" = "$COATYJS_SOURCE_COMMIT"
test "$actual_swift" = "$COATY_SWIFT_LEGACY_SOURCE_COMMIT"
test "$actual_integrity" = "$COATYJS_NPM_INTEGRITY"

printf '%s\n' "reference pins verified"
