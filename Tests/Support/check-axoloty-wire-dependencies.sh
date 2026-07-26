#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

root=${1:-.}

python3 - "$root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
package = root / "Package.swift"
wire_sources = root / "Source" / "WireCodec"
errors = []

if not package.is_file():
    errors.append(f"error: missing package manifest: {package}")
if not wire_sources.is_dir():
    errors.append(f"error: missing AxolotyWire source directory: {wire_sources}")

if not errors:
    manifest = re.sub(r"/\*.*?\*/", "", package.read_text(), flags=re.DOTALL)
    manifest = re.sub(r"//.*$", "", manifest, flags=re.MULTILINE)
    target_blocks = []
    for match in re.finditer(r"\.target\s*\(", manifest):
        start = manifest.find("(", match.start())
        depth = 0
        for index in range(start, len(manifest)):
            if manifest[index] == "(":
                depth += 1
            elif manifest[index] == ")":
                depth -= 1
                if depth == 0:
                    target_blocks.append(manifest[match.start():index + 1])
                    break

    wire_target = next((block for block in target_blocks if re.search(r'\bname\s*:\s*"AxolotyWire"', block)), None)
    if wire_target is None:
        errors.append("error: missing AxolotyWire target")
    elif re.search(r"\bdependencies\s*:", wire_target):
        errors.append("error: AxolotyWire must not declare runtime dependencies")

    import_pattern = re.compile(
        r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*\))?|public|internal|package|private)\s+)*import\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )
    for source in sorted(wire_sources.rglob("*.swift")):
        contents = re.sub(r"/\*.*?\*/", "", source.read_text(), flags=re.DOTALL)
        contents = re.sub(r"//.*$", "", contents, flags=re.MULTILINE)
        for module in import_pattern.findall(contents):
            if module != "Swift":
                errors.append(f"error: AxolotyWire must not import {module}: {source}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
