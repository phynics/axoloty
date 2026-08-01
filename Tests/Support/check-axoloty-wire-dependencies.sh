#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates that AxolotyWire depends only on the approved pinned `_JSONCore`
# package seam and imports no host runtime modules. The argument is the
# sub-package directory (default Packages/AxolotyWire).

set -eu

wire_package=${1:-Packages/AxolotyWire}

node Tests/Support/wire-dependency-check.mjs "$wire_package"
