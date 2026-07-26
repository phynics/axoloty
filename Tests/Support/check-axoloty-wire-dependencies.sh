#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

target_dir='Source/WireCodec'
forbidden_imports='Foundation Dispatch NIO NIOCore NIOPosix MQTT MQTTNIO ErrorKit Logging OSLog Combine Observation Axoloty'

found=0
for module in $forbidden_imports; do
    if grep -R -n -E "^[[:space:]]*((public|internal|package|private|@preconcurrency)[[:space:]]+)*import[[:space:]]+$module([[:space:]]|$)" "$target_dir"; then
        echo "error: AxolotyWire must not import $module" >&2
        found=1
    fi
done

if grep -A 2 'name: "AxolotyWire"' Package.swift | grep -q 'dependencies:'; then
    echo 'error: AxolotyWire must not declare runtime dependencies' >&2
    found=1
fi

if [ "$found" -ne 0 ]; then
    exit 1
fi
