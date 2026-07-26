#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Validates the AxolotyWire benchmark corpus (issue #298).
#
# Loads the corpus manifest and verifies that every payload file exists,
# matches its recorded SHA-256 and byte count, respects the wire buffer
# limits (topic <= 128 bytes, payload <= 512 bytes), and that all 13 wire
# families are covered at each of the three size classes (small, typical,
# maximum = 39 cases). Reference and generated provenance are checked too.
#
# Usage: check-benchmark-corpus.sh [corpus-dir]
#   corpus-dir defaults to Benchmarks/Corpus (relative to the working dir).

set -eu

corpus=${1:-Benchmarks/Corpus}

# Resolve to an absolute path so payload lookups work regardless of CWD.
corpus_abs=$(CDPATH= cd -- "$corpus" && pwd)

python3 - "$corpus_abs" <<'PY'
import hashlib
import json
import os
import sys

corpus = sys.argv[1]
manifest_path = os.path.join(corpus, "manifest.json")

errors = []

if not os.path.isfile(manifest_path):
    print(f"error: missing manifest: {manifest_path}", file=sys.stderr)
    sys.exit(1)

with open(manifest_path, encoding="utf-8") as f:
    manifest = json.load(f)

MAX_TOPIC = 128
MAX_PAYLOAD = 512
EXPECTED_FAMILIES = {
    "ADV", "ASC", "CHN", "CLL", "CPL", "DAD", "DSC",
    "IOV", "QRY", "RSV", "RTN", "RTV", "UPD",
}
EXPECTED_SIZES = {"small", "typical", "maximum"}

cases = manifest.get("cases", [])
if not isinstance(cases, list):
    print("error: manifest 'cases' is not a list", file=sys.stderr)
    sys.exit(1)

# 3. Verify all 13 families x 3 size classes are present (39 cases).
seen_combos = set()
seen_families = set()
seen_sizes = set()
for case in cases:
    family = case.get("family")
    size = case.get("sizeClass")
    seen_combos.add((family, size))
    seen_families.add(family)
    seen_sizes.add(size)

if len(cases) != 39:
    errors.append(f"expected 39 cases, found {len(cases)}")

missing_families = EXPECTED_FAMILIES - seen_families
if missing_families:
    errors.append(f"missing families: {sorted(missing_families)}")

extra_families = seen_families - EXPECTED_FAMILIES
if extra_families:
    errors.append(f"unexpected families: {sorted(extra_families)}")

missing_sizes = EXPECTED_SIZES - seen_sizes
if missing_sizes:
    errors.append(f"missing size classes: {sorted(missing_sizes)}")

for family in sorted(EXPECTED_FAMILIES):
    for size in sorted(EXPECTED_SIZES, key=lambda s: {"small": 0, "typical": 1, "maximum": 2}[s]):
        if (family, size) not in seen_combos:
            errors.append(f"missing case for family {family} size {size}")

# 4-9. Per-case checks.
for case in cases:
    cid = case.get("id", "<no id>")

    payload_rel = case.get("payloadFile")
    if not payload_rel:
        errors.append(f"{cid}: missing payloadFile")
        continue
    payload_path = os.path.join(corpus, payload_rel)

    # 4. payloadFile exists.
    if not os.path.isfile(payload_path):
        errors.append(f"{cid}: payload file not found: {payload_rel}")
        continue

    with open(payload_path, "rb") as f:
        payload_bytes = f.read()

    # 8. payload file size <= 512.
    if len(payload_bytes) > MAX_PAYLOAD:
        errors.append(
            f"{cid}: payload {len(payload_bytes)} bytes exceeds {MAX_PAYLOAD}"
        )

    # 5. SHA-256 matches.
    actual_sha = hashlib.sha256(payload_bytes).hexdigest()
    expected_sha = case.get("payloadSha256")
    if expected_sha is None:
        errors.append(f"{cid}: missing payloadSha256")
    elif actual_sha != expected_sha:
        errors.append(
            f"{cid}: SHA-256 mismatch (expected {expected_sha}, got {actual_sha})"
        )

    # 6. byte count matches.
    expected_bytes = case.get("payloadBytes")
    if expected_bytes is None:
        errors.append(f"{cid}: missing payloadBytes")
    elif len(payload_bytes) != expected_bytes:
        errors.append(
            f"{cid}: byte count mismatch (expected {expected_bytes}, got {len(payload_bytes)})"
        )

    # 7. topic length <= 128 bytes.
    topic = case.get("topic", "")
    topic_len = len(topic.encode("utf-8"))
    if topic_len > MAX_TOPIC:
        errors.append(
            f"{cid}: topic {topic_len} bytes exceeds {MAX_TOPIC}: {topic}"
        )

    # 9. source.type is reference or generated; generated must have a seed.
    source = case.get("source", {})
    stype = source.get("type")
    if stype == "reference":
        if not source.get("provenance"):
            errors.append(f"{cid}: reference source missing provenance")
    elif stype == "generated":
        if "seed" not in source:
            errors.append(f"{cid}: generated source missing seed")
    else:
        errors.append(f"{cid}: invalid source type {stype!r}")

if errors:
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1)

print(f"BENCHMARK CORPUS OK ({len(cases)} cases verified)")
PY
