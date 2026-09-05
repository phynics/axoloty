#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <build-log>" >&2
    exit 2
fi

if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "error: decoder-context diagnostic input is missing or unreadable: $1" >&2
    exit 2
fi

diagnostic_found=0
while IFS= read -r line; do
    case "$line" in
        *"Source/Common/Decoder+Context.swift:"*)
            context=6
            ;;
        *)
            if [ "${context:-0}" -gt 0 ]; then
                case "$line" in
                    *"type 'Any' does not conform to the 'Sendable' protocol"*)
                        diagnostic_found=1
                        ;;
                esac
                context=$((context - 1))
            fi
            ;;
    esac
done < "$1"

if [ "$diagnostic_found" -eq 1 ]; then
    echo "Swift emitted the decoder-context Sendable diagnostic" >&2
    exit 1
fi
