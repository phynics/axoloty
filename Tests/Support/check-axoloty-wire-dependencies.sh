#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates that the AxolotyWire package is dependency-free: no package-level
# dependencies, no target-level dependencies, and no non-Swift imports in its
# sources. The argument is the sub-package directory (default Packages/AxolotyWire).

set -eu

wire_package=${1:-Packages/AxolotyWire}

node Tests/Support/wire-dependency-check.mjs "$wire_package"
