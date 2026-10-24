#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

axoloty_check_consumer_paths() {
    repository_root=$1
    consumer_root=$2
    manifest="$consumer_root/Package.swift"
    if grep -E '\.package[[:space:]]*\([[:space:]]*path[[:space:]]*:' "$manifest" >/dev/null; then
        echo "error: consumer manifest contains a local path dependency" >&2
        return 1
    fi
    if grep -F "$repository_root" "$manifest" "$consumer_root"/Sources/*/*.swift >/dev/null; then
        echo "error: consumer manifest or sources mention the repository checkout path" >&2
        return 1
    fi
}

axoloty_check_core_pin() {
    resolved_file=$1
    repository_url=$2
    requested_revision=$3
    python3 - "$resolved_file" "$repository_url" "$requested_revision" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    pins = json.load(source).get("pins", [])
matches = [pin for pin in pins if pin.get("location") == sys.argv[2]]
if len(matches) != 1 or matches[0].get("state", {}).get("revision") != sys.argv[3]:
    raise SystemExit("resolved Core pin does not match the requested URL and revision")
PY
}

axoloty_check_wire_build_isolation() {
    wire_build_log=$1
    [ -r "$wire_build_log" ] || {
        echo "error: Wire consumer build log is unavailable" >&2
        return 1
    }
    # SwiftPM's legacy renderer prints "Compiling Module"; Swift Build's
    # renderer prints "[completed / total] Module" (including Unicode spaces).
    host_module='(MQTTNIO|_?NIO[A-Za-z0-9_]*|CNIO[A-Za-z0-9_]*|Logging|ErrorKit)'
    if grep -Eq "Compiling[[:space:]]+$host_module([[:space:]]|$)|^\[[^]]+\][[:space:]]+$host_module([[:space:]-]|$)" "$wire_build_log"; then
        echo "error: Wire-only consumer built host runtime targets" >&2
        return 1
    fi
}
