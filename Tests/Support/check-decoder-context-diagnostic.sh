#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <build-log>" >&2
    exit 2
fi

if grep -A 6 -F "Source/Common/Decoder+Context.swift:" "$1" | \
    grep -F "type 'Any' does not conform to the 'Sendable' protocol" >/dev/null; then
    echo "Swift emitted the decoder-context Sendable diagnostic" >&2
    exit 1
fi
