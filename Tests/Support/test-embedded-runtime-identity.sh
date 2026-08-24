#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

compiler=${CC:-clang}
if ! command -v "$compiler" >/dev/null 2>&1; then
  echo "embedded runtime identity test requires compiler '$compiler'" >&2
  exit 69
fi

"$compiler" -std=c11 -Wall -Wextra -Werror \
  -I Embedded/swift/main \
  Embedded/swift/main/runtime_identity.c \
  Tests/Support/embedded-runtime-identity-test.c \
  -o "$tmp/runtime-identity-test"
"$tmp/runtime-identity-test"
echo "embedded runtime identity host tests passed"
