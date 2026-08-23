#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

destination=${1:?usage: prepare-docc-renderer.sh <destination>}
source=/usr/share/docc/render

test -f "$source/index-template.html"
mkdir -p "$destination"
cp -R "$source/." "$destination/"
