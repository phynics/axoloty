#!/usr/bin/env bash
set -euo pipefail

module_path="${1:?usage: $0 <swift-module-search-path>}"
fixture="$(dirname "$0")/borrowed-action-sendability-probe.swift"
diagnostics="$(mktemp)"
trap 'rm -f "$diagnostics"' EXIT

if swiftc -swift-version 6 -strict-concurrency=complete -typecheck \
    -I "$module_path" "$fixture" 2>"$diagnostics"; then
    echo "borrowed action unexpectedly crossed an async isolation boundary" >&2
    exit 1
fi

if ! grep -Eqi 'sendable|task-isolated|escaping|non-sendable' "$diagnostics"; then
    cat "$diagnostics" >&2
    echo "compiler rejected the fixture for an unrelated reason" >&2
    exit 1
fi

echo "borrowed action boundary probe rejected as expected"
