#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates that the AxolotyWire package is dependency-free: no package-level
# dependencies, no target-level dependencies, and no non-Swift imports in its
# sources. The argument is the sub-package directory (default Packages/AxolotyWire).

set -eu

wire_package=${1:-Packages/AxolotyWire}

python3 - "$wire_package" <<'PY'
import pathlib
import re
import sys

pkg = pathlib.Path(sys.argv[1])
manifest_path = pkg / "Package.swift"
wire_sources = pkg / "Sources" / "AxolotyWire"
errors = []

if not manifest_path.is_file():
    errors.append(f"error: missing AxolotyWire package manifest: {manifest_path}")

if not errors:
    manifest = manifest_path.read_text()

    def code_mask(text):
        masked = list(text)
        index = 0
        block_depth = 0
        quote = None
        while index < len(text):
            if block_depth:
                if text.startswith("/*", index):
                    block_depth += 1
                    masked[index:index + 2] = "  "
                    index += 2
                elif text.startswith("*/", index):
                    block_depth -= 1
                    masked[index:index + 2] = "  "
                    index += 2
                else:
                    if text[index] != "\n":
                        masked[index] = " "
                    index += 1
            elif quote:
                if text[index] == "\\":
                    masked[index] = " "
                    if index + 1 < len(text):
                        masked[index + 1] = " "
                    index += 2
                elif text[index] == quote:
                    masked[index] = " "
                    quote = None
                    index += 1
                else:
                    if text[index] != "\n":
                        masked[index] = " "
                    index += 1
            elif text.startswith("//", index):
                end = text.find("\n", index)
                end = len(text) if end == -1 else end
                masked[index:end] = " " * (end - index)
                index = end
            elif text.startswith("/*", index):
                block_depth = 1
                masked[index:index + 2] = "  "
                index += 2
            elif text[index] == "#":
                hashes = 0
                while index + hashes < len(text) and text[index + hashes] == "#":
                    hashes += 1
                quote_start = index + hashes
                if quote_start < len(text) and text[quote_start] == '"':
                    delimiter = '"""' if text.startswith('"""', quote_start) else '"'
                    closing = delimiter + ("#" * hashes)
                    content_start = quote_start + len(delimiter)
                    end = text.find(closing, content_start)
                    end = len(text) if end == -1 else end + len(closing)
                    for position in range(index, end):
                        if text[position] != "\n":
                            masked[position] = " "
                    index = end
                else:
                    index += 1
            elif text[index] in ('"', "'"):
                quote = text[index]
                masked[index] = " "
                index += 1
            else:
                index += 1
        return "".join(masked)

    structure = code_mask(manifest)

    # The AxolotyWire package must not declare any package-level dependencies.
    if re.search(r"\.package\s*\(", structure):
        errors.append("error: AxolotyWire package must not declare package dependencies")

    target_blocks = []
    for match in re.finditer(r"\.target\s*\(", structure):
        start = structure.find("(", match.start())
        depth = 0
        for index in range(start, len(structure)):
            if structure[index] == "(":
                depth += 1
            elif structure[index] == ")":
                depth -= 1
                if depth == 0:
                    target_blocks.append(manifest[match.start():index + 1])
                    break

    wire_target = next((block for block in target_blocks if re.search(r'\bname\s*:\s*"AxolotyWire"', block)), None)
    if wire_target is None:
        errors.append("error: missing AxolotyWire target")
    else:
        path = re.search(r'\bpath\s*:\s*"([^"]+)"', wire_target)
        if path is None or path.group(1) != "Sources/AxolotyWire":
            errors.append("error: AxolotyWire must declare path: Sources/AxolotyWire")
        elif re.search(r"\bdependencies\s*:", code_mask(wire_target)):
            errors.append("error: AxolotyWire target must not declare runtime dependencies")

    if not wire_sources.is_dir():
        errors.append(f"error: missing AxolotyWire source directory: {wire_sources}")

    import_pattern = re.compile(
        r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*\))?|public|internal|package|private)\s+)*import\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )
    for source in sorted(wire_sources.rglob("*.swift")):
        contents = code_mask(source.read_text())
        for module in import_pattern.findall(contents):
            if module != "Swift":
                errors.append(f"error: AxolotyWire must not import {module}: {source}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
PY
