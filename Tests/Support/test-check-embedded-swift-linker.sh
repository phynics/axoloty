#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host-only self-test for the Embedded Swift linker probe. The fake idf.py
# records command arguments, creates the small set of linker artifacts the
# checker inspects, and can emit a deterministic build failure.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
checker="$root/Tests/Support/check-embedded-swift-linker.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
fake_idf="$tmp/idf"
build_dir="$tmp/build"
records="$tmp/idf-args"
mkdir -p "$fake_bin" "$fake_idf"

cat > "$fake_bin/idf.py" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import sys

arguments = sys.argv[1:]
with open(os.environ["FAKE_IDF_ARGS"], "a", encoding="utf-8") as output:
    output.write(f"IDF_PY_BUILD_JOBS={os.environ.get('IDF_PY_BUILD_JOBS', '')} ")
    output.write(" ".join(arguments) + "\n")

build_index = arguments.index("-B") + 1
build_dir = pathlib.Path(arguments[build_index])
action = next(value for value in ("set-target", "build") if value in arguments)
log_dir = build_dir / "log"
log_dir.mkdir(parents=True, exist_ok=True)

if action == "build" and os.environ.get("FAKE_IDF_BUILD_FAILURE") == "1":
    (log_dir / "idf_py_stdout.txt").write_text("fake ESP-IDF build log\n", encoding="utf-8")
    print("ninja: fake linker failure", file=sys.stderr)
    raise SystemExit(42)

if action == "build":
    (build_dir / "axoloty-swift.elf").touch()
    (build_dir / "axoloty-swift.map").write_text("libswiftUnicodeDataTables.a\n", encoding="utf-8")
    sections = build_dir / "esp-idf/esp_system/ld/sections.ld"
    sections.parent.mkdir(parents=True, exist_ok=True)
    sections.write_text(
        "*(.got .got.* .got.plt .got.plt.*)\n"
        "Swift UnicodeDataTables requires .got/.got.plt\n",
        encoding="utf-8",
    )
PY
chmod +x "$fake_bin/idf.py"

cat > "$fake_bin/riscv32-esp-elf-nm" <<'SH'
#!/bin/sh
printf '00000000 T _swift_stdlib_getNormData\n00000000 T axoloty_unicode_linker_probe\n'
SH
chmod +x "$fake_bin/riscv32-esp-elf-nm"

cat > "$fake_idf/export.sh" <<'SH'
:
SH

if ! IDF_PATH="$fake_idf" PATH="$fake_bin:$PATH" \
    FAKE_IDF_ARGS="$records" \
    AXOLOTY_EMBEDDED_LINKER_BUILD_DIR="$build_dir" \
    AXOLOTY_EMBEDDED_LINKER_JOBS=2 \
    RISCV_NM="$fake_bin/riscv32-esp-elf-nm" \
    "$checker"; then
    echo "expected linker checker success with fake ESP-IDF" >&2
    exit 1
fi
grep -F -- "-DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON set-target esp32c6" "$records" >/dev/null
grep -F -- "IDF_PY_BUILD_JOBS=2" "$records" >/dev/null
grep -F -- "-DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON build" "$records" >/dev/null
! grep -F -- "build -j" "$records" >/dev/null

failure_status=0
if output=$(IDF_PATH="$fake_idf" PATH="$fake_bin:$PATH" \
    FAKE_IDF_ARGS="$records" FAKE_IDF_BUILD_FAILURE=1 \
    AXOLOTY_EMBEDDED_LINKER_BUILD_DIR="$build_dir" \
    AXOLOTY_EMBEDDED_LINKER_JOBS=3 \
    RISCV_NM="$fake_bin/riscv32-esp-elf-nm" \
    "$checker" 2>&1); then
    echo "expected linker checker build failure" >&2
    exit 1
else
    failure_status=$?
fi
test "$failure_status" -eq 42
printf '%s\n' "$output" | grep -F "ninja: fake linker failure" >/dev/null
printf '%s\n' "$output" | grep -F "fake ESP-IDF build log" >/dev/null
grep -F -- "IDF_PY_BUILD_JOBS=3" "$records" >/dev/null
grep -F -- "-DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON build" "$records" >/dev/null

if output=$(IDF_PATH="$fake_idf" PATH="$fake_bin:$PATH" \
    FAKE_IDF_ARGS="$records" AXOLOTY_EMBEDDED_LINKER_JOBS=0 \
    AXOLOTY_EMBEDDED_LINKER_BUILD_DIR="$build_dir" \
    "$checker" 2>&1); then
    echo "expected zero linker jobs to be rejected" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -F "AXOLOTY_EMBEDDED_LINKER_JOBS must be" >/dev/null

bad_idf="$tmp/bad-idf"
mkdir -p "$bad_idf"
cat > "$bad_idf/export.sh" <<'SH'
echo "fake ESP-IDF export failure" >&2
return 1
SH
if output=$(IDF_PATH="$bad_idf" PATH="$fake_bin:$PATH" \
    FAKE_IDF_ARGS="$records" AXOLOTY_EMBEDDED_LINKER_BUILD_DIR="$build_dir" \
    "$checker" 2>&1); then
    echo "expected ESP-IDF setup failure" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -F "fake ESP-IDF export failure" >/dev/null

echo "embedded linker checker self-test passed"
