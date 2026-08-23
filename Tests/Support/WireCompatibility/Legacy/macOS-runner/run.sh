#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "The legacy runner can only execute on macOS." >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$SCRIPT_DIR/verify-pin.sh"

BIN="$SCRIPT_DIR/.build/debug/LegacyCoatySwiftScenarioRunner"
if [ ! -x "$BIN" ]; then
  echo "Runner is not built; execute $SCRIPT_DIR/prepare.sh before starting capture." >&2
  exit 2
fi
exec "$BIN" "$@"
