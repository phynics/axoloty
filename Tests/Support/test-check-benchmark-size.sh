#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Self-test for check-benchmark-size.sh (issue #299).
#
# 1. Copies pinned fixture raw tool outputs to a temp dir, adds the real
#    Package.swift manifests, and runs the --parse mode.
# 2. Verifies the parsed JSON values match the expected fixture values.
# 3. Creates a baseline from the parsed JSON and runs --compare; it must pass.
# 4. Tampers the baseline (byte count beyond tolerance) and verifies --compare
#    fails.
# 5. Tampers the Package.swift to add a host dependency to AxolotyWireConsumer
#    and verifies the host-dep-leak check fails.
# 6. Prints SELF-TEST OK on success.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-benchmark-size.sh"
fixtures="$root/Tests/Support/fixtures/benchmark-size"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Assemble a raw-dir from pinned fixtures + real Package.swift manifests.
raw_dir="$tmp/raw"
mkdir -p "$raw_dir"
cp "$fixtures"/* "$raw_dir/"
cp "$root/Package.swift" "$raw_dir/package-swift.txt"
cp "$root/Packages/AxolotyWire/Package.swift" "$raw_dir/wire-package-swift.txt"

# 2. Run --parse and verify parsed values.
current_json="$tmp/size-baseline.json"
sh "$checker" --parse "$raw_dir" > "$current_json"

python3 - "$current_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)

errors = []

wire = doc["consumers"]["AxolotyWireConsumer"]
host = doc["consumers"]["AxolotyConsumer"]

# AxolotyWireConsumer: pinned fixture values.
if wire["unstrippedBytes"] != 50640:
    errors.append(f"wire unstrippedBytes: expected 50640, got {wire['unstrippedBytes']}")
if wire["strippedBytes"] != 12000:
    errors.append(f"wire strippedBytes: expected 12000, got {wire['strippedBytes']}")
if wire["sections"]["text"] != 42000:
    errors.append(f"wire .text: expected 42000, got {wire['sections']['text']}")
if wire["sections"]["rodata"] != 8000:
    errors.append(f"wire .rodata: expected 8000, got {wire['sections']['rodata']}")
if wire["sections"]["data"] != 480:
    errors.append(f"wire .data: expected 480, got {wire['sections']['data']}")
if wire["sections"]["bss"] != 160:
    errors.append(f"wire .bss: expected 160, got {wire['sections']['bss']}")
if wire["sha256"] != "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2":
    errors.append(f"wire sha256 mismatch: {wire['sha256']}")
if "libswiftCore.so" not in wire["dynamicLibraries"]:
    errors.append("wire dynamicLibraries missing libswiftCore.so")
if "libssl.so.3" in wire["dynamicLibraries"]:
    errors.append("wire dynamicLibraries should not contain libssl.so.3")
if wire["dependencyClosure"] != ["AxolotyWire"]:
    errors.append(f"wire dependencyClosure: expected ['AxolotyWire'], got {wire['dependencyClosure']}")
if wire["hostDependencyCheck"] != "passed":
    errors.append(f"wire hostDependencyCheck: expected 'passed', got {wire['hostDependencyCheck']}")

# AxolotyConsumer: pinned fixture values.
if host["unstrippedBytes"] != 2652800:
    errors.append(f"host unstrippedBytes: expected 2652800, got {host['unstrippedBytes']}")
if host["strippedBytes"] != 980000:
    errors.append(f"host strippedBytes: expected 980000, got {host['strippedBytes']}")
if host["sections"]["text"] != 2200000:
    errors.append(f"host .text: expected 2200000, got {host['sections']['text']}")
if "libssl.so.3" not in host["dynamicLibraries"]:
    errors.append("host dynamicLibraries missing libssl.so.3")
if host["hostDependencyCheck"] != "n/a":
    errors.append(f"host hostDependencyCheck: expected 'n/a', got {host['hostDependencyCheck']}")
# AxolotyConsumer closure must include host packages.
closure = set(host["dependencyClosure"])
for required in ("Axoloty", "AxolotyWire", "mqtt-nio", "swift-nio"):
    if required not in closure:
        errors.append(f"host dependencyClosure missing {required}: {host['dependencyClosure']}")

if errors:
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1)

print("parse verification passed")
PY

# 3. Create a baseline from the current JSON and verify --compare passes.
baseline="$tmp/baseline.json"
cp "$current_json" "$baseline"
sh "$checker" --compare "$current_json" "$baseline" >/dev/null

# 4. Tamper the baseline (byte count beyond ±64 tolerance) and verify failure.
python3 - "$baseline" "$tmp/tampered.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)

# Inflate the unstripped size well beyond the 64-byte tolerance.
doc["consumers"]["AxolotyWireConsumer"]["unstrippedBytes"] += 500

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

if sh "$checker" --compare "$current_json" "$tmp/tampered.json" >/dev/null 2>&1; then
    echo "error: expected --compare to fail when byte count differs beyond tolerance" >&2
    exit 1
fi

# Confirm the failure message names the field that changed.
if ! sh "$checker" --compare "$current_json" "$tmp/tampered.json" 2>&1 \
        | grep -qi "unstrippedBytes"; then
    echo "error: expected unstrippedBytes in the diff output" >&2
    exit 1
fi

# 5. Tamper Package.swift to add a host dependency to AxolotyWireConsumer
#    and verify the host-dep-leak check fails.
python3 - "$root/Package.swift" "$raw_dir/package-swift.txt" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()

# Replace the AxolotyWireConsumer target's dependencies to include mqtt-nio.
old = 'name: "AxolotyWireConsumer",\n            dependencies: [\n                .product(name: "AxolotyWire", package: "AxolotyWire"),\n            ]'
new = 'name: "AxolotyWireConsumer",\n            dependencies: [\n                .product(name: "AxolotyWire", package: "AxolotyWire"),\n                .product(name: "MQTTNIO", package: "mqtt-nio"),\n            ]'
text = text.replace(old, new)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(text)
PY

leaked_json="$tmp/leaked.json"
sh "$checker" --parse "$raw_dir" > "$leaked_json"

python3 - "$leaked_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)

check = doc["consumers"]["AxolotyWireConsumer"]["hostDependencyCheck"]
if check != "FAILED":
    print(f"error: expected hostDependencyCheck FAILED, got {check!r}", file=sys.stderr)
    sys.exit(1)
PY

# The --compare mode must also fail on a FAILED host-dep check.
leaked_baseline="$tmp/leaked-baseline.json"
cp "$leaked_json" "$leaked_baseline"
if sh "$checker" --compare "$leaked_json" "$leaked_baseline" >/dev/null 2>&1; then
    echo "error: expected --compare to fail when hostDependencyCheck is FAILED" >&2
    exit 1
fi

if ! sh "$checker" --compare "$leaked_json" "$leaked_baseline" 2>&1 \
        | grep -qi "host dependencies leaked"; then
    echo "error: expected 'host dependencies leaked' in failure output" >&2
    exit 1
fi

echo "SELF-TEST OK"
