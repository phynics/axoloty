#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Records binary-size and dependency-closure baselines for the AxolotyWire and
# Axoloty release consumers (issue #299).
#
# Builds both consumers in release mode, measures binary size (unstripped and
# stripped), ELF section sizes, dynamic libraries, SHA-256, and the SwiftPM
# resolved-package closure, then compares against the checked-in baseline at
# Benchmarks/Baselines/size-baseline.json.
#
# The AxolotyWireConsumer closure is verified to contain no host runtime
# packages (mqtt-nio, swift-nio, NIOSSL, NIOTransportServices, swift-log,
# ErrorKit, swift-json/IKigaJSON).
#
# Usage:
#   check-benchmark-size.sh [output-dir]
#       Full run: build both consumers, measure, compare against baseline.
#       output-dir defaults to .testing/benchmarks/<short-hash>.
#
#   check-benchmark-size.sh --parse <raw-dir>
#       Parse raw tool outputs in <raw-dir> and emit JSON to stdout.
#       Used by the self-test (test-check-benchmark-size.sh).
#
#   check-benchmark-size.sh --compare <new.json> <baseline.json>
#       Compare two baseline JSON files. Exits 0 on match, 1 on diff.
#       If the baseline is a template (no "consumers" key), populates it and
#       prints BASELINE CREATED.
#
# Must run inside the devcontainer for the default mode (needs swift,
# llvm-size, readelf, strip, ldd). The --parse and --compare modes only need
# python3.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# --- Mode dispatch ---

mode=default
parse_dir=""
compare_new=""
compare_base=""
output_dir=""

while [ $# -gt 0 ]; do
    case "$1" in
        --parse)
            mode=parse
            parse_dir="$2"
            shift 2
            ;;
        --compare)
            mode=compare
            compare_new="$2"
            compare_base="$3"
            shift 3
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            if [ -z "$output_dir" ]; then
                output_dir="$1"
            else
                echo "error: unexpected argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

# --- Compare mode: compare two JSON baseline files ---

if [ "$mode" = "compare" ]; then
    python3 - "$compare_new" "$compare_base" <<'PY'
import json
import sys

TOLERANCE = 64


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def compare(current, baseline, baseline_path):
    """Return (exit_code, message)."""
    # If baseline is a template or missing consumers, create it.
    if "consumers" not in baseline:
        with open(baseline_path, "w", encoding="utf-8") as f:
            json.dump(current, f, indent=2)
            f.write("\n")
        return (0, "BASELINE CREATED")

    # Fail immediately if the AxolotyWireConsumer host-dep check failed.
    wire = current.get("consumers", {}).get("AxolotyWireConsumer", {})
    if wire.get("hostDependencyCheck") == "FAILED":
        return (1, "BENCHMARK SIZE FAIL: host dependencies leaked into "
                   "AxolotyWire consumer")

    diffs = []
    for name in ("AxolotyWireConsumer", "AxolotyConsumer"):
        cur = current.get("consumers", {}).get(name, {})
        base = baseline.get("consumers", {}).get(name, {})

        # Numeric size fields with ±64 byte tolerance.
        for field in ("unstrippedBytes", "strippedBytes"):
            c = cur.get(field, 0)
            b = base.get(field, 0)
            if abs(c - b) > TOLERANCE:
                diffs.append(
                    f"  {name}.{field}: {b} -> {c} "
                    f"(diff {c - b:+d}, tolerance +/-{TOLERANCE})"
                )

        # ELF section sizes with ±64 byte tolerance.
        cur_secs = cur.get("sections", {})
        base_secs = base.get("sections", {})
        for sec in ("text", "rodata", "data", "bss"):
            c = cur_secs.get(sec, 0)
            b = base_secs.get(sec, 0)
            if abs(c - b) > TOLERANCE:
                diffs.append(
                    f"  {name}.sections.{sec}: {b} -> {c} "
                    f"(diff {c - b:+d}, tolerance +/-{TOLERANCE})"
                )

        # SHA-256: exact match for AxolotyWireConsumer (deterministic).
        # The AxolotyConsumer SHA may vary if it links dynamic libraries at
        # different paths, so it is not compared.
        if name == "AxolotyWireConsumer":
            c = cur.get("sha256", "")
            b = base.get("sha256", "")
            if c != b:
                diffs.append(
                    f"  {name}.sha256: {b} -> {c} (must match exactly)"
                )

        # Dynamic libraries: exact set match.
        c_libs = set(cur.get("dynamicLibraries", []))
        b_libs = set(base.get("dynamicLibraries", []))
        if c_libs != b_libs:
            added = sorted(c_libs - b_libs)
            removed = sorted(b_libs - c_libs)
            diffs.append(
                f"  {name}.dynamicLibraries: +{added} -{removed}"
            )

        # Dependency closure: exact set match.
        c_deps = set(cur.get("dependencyClosure", []))
        b_deps = set(base.get("dependencyClosure", []))
        if c_deps != b_deps:
            added = sorted(c_deps - b_deps)
            removed = sorted(b_deps - c_deps)
            diffs.append(
                f"  {name}.dependencyClosure: +{added} -{removed}"
            )

        # hostDependencyCheck status must not change.
        c_check = cur.get("hostDependencyCheck", "")
        b_check = base.get("hostDependencyCheck", "")
        if c_check != b_check:
            diffs.append(
                f"  {name}.hostDependencyCheck: {b_check} -> {c_check}"
            )

    if diffs:
        msg = "BENCHMARK SIZE FAIL: measurements differ from baseline\n"
        msg += "\n".join(diffs)
        msg += ("\n\nBaseline changes require an explicit update to "
                "Benchmarks/Baselines/size-baseline.json.")
        return (1, msg)

    return (0, "BENCHMARK SIZE OK")


current = load_json(sys.argv[1])
baseline_path = sys.argv[2]

try:
    baseline = load_json(baseline_path)
except (OSError, json.JSONDecodeError):
    # No baseline file or invalid JSON: create from current.
    with open(baseline_path, "w", encoding="utf-8") as f:
        json.dump(current, f, indent=2)
        f.write("\n")
    print("BASELINE CREATED")
    sys.exit(0)

code, msg = compare(current, baseline, baseline_path)
if code == 0:
    print(msg)
else:
    print(msg, file=sys.stderr)
sys.exit(code)
PY
    exit $?
fi

# --- Parse mode: parse raw tool outputs, emit JSON to stdout ---

if [ "$mode" = "parse" ]; then
    python3 - "$parse_dir" "$root" <<'PY'
import json
import os
import re
import subprocess
import sys

HOST_DEPS = {
    "mqtt-nio", "swift-nio", "swift-nio-ssl",
    "swift-nio-transport-services", "swift-log", "ErrorKit",
    "swift-json", "IkigaJSON", "swift-docc-plugin",
}


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def read_int(path):
    text = read_text(path).strip()
    if not text:
        return 0
    m = re.search(r"\d+", text)
    return int(m.group()) if m else 0


def parse_llvm_size(text):
    """Parse SysV ``-A`` output (llvm-size or GNU size).

    Returns a dict with text, rodata, data, bss section sizes.
    """
    sections = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] in (".text", ".rodata",
                                           ".data", ".bss"):
            try:
                sections[parts[0].lstrip(".")] = int(parts[1])
            except ValueError:
                pass
    return {
        "text": sections.get("text", 0),
        "rodata": sections.get("rodata", 0),
        "data": sections.get("data", 0),
        "bss": sections.get("bss", 0),
    }


def parse_readelf_needed(text):
    """Extract NEEDED shared library names from ``readelf -d`` output."""
    libs = []
    for line in text.splitlines():
        m = re.search(r"\(NEEDED\)\s*Shared library:\s*\[([^\]]+)\]",
                      line)
        if m:
            libs.append(m.group(1))
    return libs


def parse_sha256(text):
    """Extract the hex digest from ``sha256sum`` output."""
    stripped = text.strip()
    if not stripped:
        return ""
    return stripped.split()[0]


def parse_flatlist(text):
    """Parse ``swift package show-dependencies --format flatlist`` output."""
    deps = []
    for line in text.splitlines():
        line = line.strip()
        # Strip tree-drawing characters (the flatlist format should not
        # include them, but be defensive).
        line = line.lstrip("\u2502\u251c\u2514\u2500 ")
        if not line:
            continue
        name = line.split("@")[0].strip()
        if name:
            deps.append(name)
    return deps


def extract_target_deps(package_swift, target_name):
    """Extract dependency identifiers for a target from Package.swift text.

    Returns a list of target/product names. Handles both bare string
    dependencies (``"Axoloty"``) and ``.product(name:package:)`` references.
    """
    pattern = (
        r"\.(?:executable)?Target\(\s*"
        r'name:\s*"' + re.escape(target_name) + r'"\s*,\s*'
        r"dependencies:\s*\[([^\]]*)\]"
    )
    match = re.search(pattern, package_swift, re.DOTALL)
    if not match:
        return []
    deps_text = match.group(1)
    deps = []
    # Bare string literals (target or product names).
    for m in re.finditer(r'"([^"]+)"', deps_text):
        deps.append(m.group(1))
    # .product(name: "X", package: "Y") — record the package name.
    for m in re.finditer(
        r'\.product\(\s*name:\s*"[^"]+"\s*,\s*package:\s*"([^"]+)"',
        deps_text,
    ):
        deps.append(m.group(1))
    return deps


def check_host_leak(closure):
    """Return True if no host package name appears in the closure."""
    for dep in closure:
        dep_lower = dep.lower()
        for host in HOST_DEPS:
            if host.lower() in dep_lower:
                return False
    return True


def git_commit(root_dir):
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=root_dir, text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return "unknown"


raw_dir = sys.argv[1]
root_dir = sys.argv[2] if len(sys.argv) > 2 else ""

flatlist = parse_flatlist(
    read_text(os.path.join(raw_dir, "deps-flatlist.txt"))
)
package_swift = read_text(
    os.path.join(raw_dir, "package-swift.txt")
)
swift_version = read_text(
    os.path.join(raw_dir, "swift-version.txt")
).strip()

consumers = {}
for name in ("AxolotyWireConsumer", "AxolotyConsumer"):
    consumer = {}
    consumer["unstrippedBytes"] = read_int(
        os.path.join(raw_dir, f"wc-unstripped-{name}.txt")
    )
    consumer["strippedBytes"] = read_int(
        os.path.join(raw_dir, f"wc-stripped-{name}.txt")
    )
    consumer["sections"] = parse_llvm_size(
        read_text(os.path.join(raw_dir, f"llvm-size-{name}.txt"))
    )
    consumer["dynamicLibraries"] = parse_readelf_needed(
        read_text(os.path.join(raw_dir, f"readelf-d-{name}.txt"))
    )
    consumer["sha256"] = parse_sha256(
        read_text(os.path.join(raw_dir, f"sha256-{name}.txt"))
    )

    # Compute the target-level transitive dependency closure.
    direct_deps = extract_target_deps(package_swift, name)
    if name == "AxolotyWireConsumer":
        # AxolotyWire is a zero-dependency local package, so the
        # transitive closure is just the direct dependencies.
        closure = sorted(set(direct_deps))
        consumer["dependencyClosure"] = closure
        consumer["hostDependencyCheck"] = (
            "passed" if check_host_leak(closure) else "FAILED"
        )
    else:
        # The Axoloty target pulls in the full host runtime graph.
        closure = sorted(set(direct_deps + flatlist))
        consumer["dependencyClosure"] = closure
        consumer["hostDependencyCheck"] = "n/a"

    consumers[name] = consumer

result = {
    "commit": git_commit(root_dir),
    "swiftVersion": swift_version,
    "buildMode": "release",
    "buildFlags": "-c release -Xswiftc -O -Xswiftc -wmo",
    "consumers": consumers,
}

print(json.dumps(result, indent=2))
PY
    exit $?
fi

# --- Default mode: build, measure, compare ---

if [ -z "$output_dir" ]; then
    short=$(cd "$root" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
    output_dir="$root/.testing/benchmarks/$short"
fi
mkdir -p "$output_dir"

cd "$root"

echo "Building AxolotyWireConsumer (release)..."
swift build -c release --product AxolotyWireConsumer \
    --cache-path .swiftpm-cache --disable-automatic-resolution

echo "Building AxolotyConsumer (release)..."
swift build -c release --product AxolotyConsumer \
    --cache-path .swiftpm-cache --disable-automatic-resolution

wire_bin="$root/.build/release/AxolotyWireConsumer"
host_bin="$root/.build/release/AxolotyConsumer"
for b in "$wire_bin" "$host_bin"; do
    if [ ! -f "$b" ]; then
        echo "error: binary not found: $b" >&2
        exit 1
    fi
done

# Locate the ELF section-size tool.
size_tool=""
for candidate in llvm-size /usr/local/swift/usr/bin/llvm-size size; do
    if command -v "$candidate" >/dev/null 2>&1; then
        size_tool="$candidate"
        break
    fi
done
if [ -z "$size_tool" ]; then
    echo "error: no size tool found (tried llvm-size, size)" >&2
    exit 1
fi

raw_dir=$(mktemp -d)
trap 'rm -rf "$raw_dir"' EXIT

measure_binary() {
    _bin="$1"
    _name="$2"
    # Unstripped file size.
    wc -c < "$_bin" > "$raw_dir/wc-unstripped-$_name.txt"
    # Stripped file size.
    _stripped=$(mktemp)
    cp "$_bin" "$_stripped"
    strip "$_stripped" 2>/dev/null || true
    wc -c < "$_stripped" > "$raw_dir/wc-stripped-$_name.txt"
    rm -f "$_stripped"
    # ELF section sizes (SysV format).
    "$size_tool" -A "$_bin" > "$raw_dir/llvm-size-$_name.txt" 2>&1 || true
    # Dynamic library dependencies.
    readelf -d "$_bin" > "$raw_dir/readelf-d-$_name.txt" 2>&1 || true
    ldd "$_bin" > "$raw_dir/ldd-$_name.txt" 2>&1 || true
    # Artifact SHA-256.
    sha256sum "$_bin" | awk '{print $1}' > "$raw_dir/sha256-$_name.txt"
}

measure_binary "$wire_bin" AxolotyWireConsumer
measure_binary "$host_bin" AxolotyConsumer

# Swift compiler version.
swift --version > "$raw_dir/swift-version.txt" 2>&1

# SwiftPM resolved-package closure (package-level flatlist).
swift package show-dependencies --format flatlist \
    > "$raw_dir/deps-flatlist.txt" 2>&1 || true

# Copy Package.swift manifests for per-target dependency parsing.
cp "$root/Package.swift" "$raw_dir/package-swift.txt"
cp "$root/Packages/AxolotyWire/Package.swift" "$raw_dir/wire-package-swift.txt"

# Parse raw outputs into JSON.
current_json=$(sh "$0" --parse "$raw_dir")

# Write output JSON and preserve raw outputs for debugging.
printf '%s\n' "$current_json" > "$output_dir/size-baseline.json"
mkdir -p "$output_dir/raw"
cp -R "$raw_dir/"* "$output_dir/raw/" 2>/dev/null || true

echo "Wrote $output_dir/size-baseline.json"

# Compare against the checked-in baseline.
baseline="$root/Benchmarks/Baselines/size-baseline.json"
sh "$0" --compare "$output_dir/size-baseline.json" "$baseline"
