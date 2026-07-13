#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

if [ "$(uname -s)" != Darwin ]; then
  echo "The legacy runner can only be prepared on macOS." >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
swift build --package-path "$SCRIPT_DIR"
"$SCRIPT_DIR/verify-pin.sh"
