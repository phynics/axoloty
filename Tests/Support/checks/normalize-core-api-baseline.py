# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Normalize SwiftPM symbol graphs into the reviewed Core API inventory."""

from __future__ import annotations

import json
import pathlib
import sys


PRODUCTS = (
    ("Axoloty", "Host runtime, bounded scheduling, transport ownership, and diagnostics."),
    ("AxolotyWire", "Profile-neutral wire syntax, codecs, validation, and wire values."),
    ("AxolotyProtocol", "Sealed profiles, routing keys, bounded state, and shared processor."),
    ("AxolotyObjectModel", "Bounded semantic objects, schemas, presence, and predicates."),
    ("AxolotyStaticRuntime", "Fixed synchronous composition around the shared processor."),
    ("AxolotyMQTT", "The host MQTT transport adapter."),
)


def read_product(graph_paths: list[pathlib.Path], module: str, ownership: str) -> dict[str, object]:
    if not graph_paths:
        raise SystemExit(f"No symbol graph emitted for {module}")

    symbols: dict[str, dict[str, str]] = {}
    for graph_path in graph_paths:
        graph = json.loads(graph_path.read_text(encoding="utf-8"))
        actual_module = graph.get("module", {}).get("name")
        if actual_module != module:
            continue
        for symbol in graph.get("symbols", []):
            if symbol.get("accessLevel") not in {"public", "open"}:
                continue
            precise = symbol.get("identifier", {}).get("precise")
            if not precise:
                raise SystemExit(f"Public symbol in {graph_path} has no precise identifier")
            fragments = symbol.get("declarationFragments", [])
            declaration = "".join(fragment.get("spelling", "") for fragment in fragments)
            symbols[precise] = {
                "identifier": precise,
                "name": symbol.get("names", {}).get("title", precise),
                "kind": symbol.get("kind", {}).get("identifier", "unknown"),
                "declaration": declaration,
                "classification": "intentional-stable-api",
            }

    if not symbols:
        raise SystemExit(f"No public symbols found for {module}")
    return {
        "product": module,
        "ownership": ownership,
        "symbols": [symbols[key] for key in sorted(symbols)],
    }


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize-core-api-baseline.py <symbol-graph-root> <output>")
    graph_root = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    graph_paths = sorted(graph_root.rglob("*.symbols.json"))
    if not graph_paths:
        raise SystemExit(f"No symbol graphs found under {graph_root}")
    document = {
        "schemaVersion": 1,
        "baselineVersion": "1.0.0",
        "toolchain": "Swift 6.4",
        "generator": "swift package dump-symbol-graph",
        "classification": "Every listed declaration is intentional stable API for Core 1.0.",
        "products": [read_product(graph_paths, module, ownership) for module, ownership in PRODUCTS],
    }
    output.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
