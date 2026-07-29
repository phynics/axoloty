#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Vector capture is the smoke harness with a stricter, complete corpus.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EMBEDDED_VALIDATOR="$script_dir/embedded-swift-test-validator.mjs" \
  EMBEDDED_VALIDATOR_FACTORY=createEmbeddedSwiftTestValidator \
  exec "$script_dir/embedded-swift-smoke.sh" "$@"
