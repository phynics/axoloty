#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Compile and partially link the portable Axoloty Core profile as Embedded
# Swift. This gate deliberately owns no firmware project, SDK, broker, or
# hardware state. It proves the dependency order used by a downstream Core
# consumer, expands a real StaticIoActor declaration with the production macro
# plugin, and retains the RISC-V and host parser probes from the retired
# AxolotyWire-only gate.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/../../.." && pwd)

command -v swift >/dev/null 2>&1 || {
    echo "FAIL: swift is required to run the Embedded consumer preparation command" >&2
    exit 1
}
command -v swiftc >/dev/null 2>&1 || {
    echo "FAIL: swiftc is required for the Embedded Swift Core check" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || {
    echo "FAIL: node is required to read the preparation report" >&2
    exit 1
}
command -v realpath >/dev/null 2>&1 || {
    echo "FAIL: realpath is required to validate Core and scratch boundaries" >&2
    exit 1
}
command -v clang >/dev/null 2>&1 || {
    echo "FAIL: clang is required for the host parser probe" >&2
    exit 1
}

# The selected Core checkout is an explicit boundary. The default is useful
# for the repository's ordinary check, while callers may point this gate at a
# separate clean checkout or worktree.
AXOLOTY_SOURCE_DIR=${AXOLOTY_SOURCE_DIR:-$root_dir}
export AXOLOTY_SOURCE_DIR
source_root=$(CDPATH= cd -- "$AXOLOTY_SOURCE_DIR" && pwd -P)

path_is_inside_source() {
    candidate=$(realpath -m -- "$1")
    case "$candidate" in
        "$source_root"|"$source_root"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Keep all generated compiler and macro state in a caller-owned temporary
# tree. In particular, do not use the firmware build directory or a package's
# implicit .build directory for this Core-only proof.
# The repository container sets TMPDIR under the mounted Core checkout for
# bridge artifacts. That location is intentionally invalid for the public
# consumer command, so use an independent caller-owned default unless the
# caller supplies an explicit absolute directory.
scratch_parent=${AXOLOTY_EMBEDDED_CORE_CHECK_DIR:-/tmp/axoloty-embedded-core}
case "$scratch_parent" in
    /*) ;;
    *)
        echo "FAIL: AXOLOTY_EMBEDDED_CORE_CHECK_DIR must be absolute: $scratch_parent" >&2
        exit 1
        ;;
esac
if path_is_inside_source "$scratch_parent"; then
    if [ -n "${AXOLOTY_EMBEDDED_CORE_CHECK_DIR:-}" ]; then
        echo "FAIL: AXOLOTY_EMBEDDED_CORE_CHECK_DIR must be outside AXOLOTY_SOURCE_DIR: $scratch_parent" >&2
        exit 1
    fi
    scratch_parent=/tmp/axoloty-embedded-core
fi
mkdir -p -- "$scratch_parent"
workdir=$(mktemp -d "$scratch_parent/run.XXXXXX")
trap 'rm -rf -- "$workdir"' EXIT HUP INT TERM

compiler_dir="$workdir/compiler"
macro_scratch=${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR:-$workdir/macro-tools}
if path_is_inside_source "$macro_scratch"; then
    echo "FAIL: AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR must be outside AXOLOTY_SOURCE_DIR: $macro_scratch" >&2
    exit 1
fi
preparation_report="$workdir/preparation.json"
mkdir -p -- "$compiler_dir" "$macro_scratch"

echo "Preparing Core consumer tools through axoloty-tool..."
tool=${AXOLOTY_TOOL:-/opt/axoloty/bin/axoloty-tool}
"$tool" embedded consumer prepare \
    --scratch "$macro_scratch" \
    --output "$preparation_report" \
    >"$workdir/preparation.stdout"
[ -s "$preparation_report" ] || {
    echo "FAIL: consumer preparation did not produce a report" >&2
    exit 1
}

json_field() {
    field=$1
    node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); let current=value; for (const key of process.argv[2].split(".")) current=current[key]; if (typeof current === "boolean") process.stdout.write(current ? "true" : "false"); else if (Array.isArray(current)) process.stdout.write(current.join("\n")); else process.stdout.write(String(current));' "$preparation_report" "$field"
}

test "$(json_field status)" = prepared || { echo "FAIL: preparation status is not prepared" >&2; exit 1; }
test "$(json_field core.dirty)" = false || { echo "FAIL: Core checkout is dirty" >&2; exit 1; }
test "$(json_field core.sourceDir)" = "$AXOLOTY_SOURCE_DIR" || { echo "FAIL: preparation report selected a different Core root" >&2; exit 1; }

source_root=$(json_field core.sourceDir)
json_core_dir=$(json_field jsonCore.sourceDir)
macro_tool=$(json_field staticRuntimeMacro.executable)
macro_scratch=$(json_field staticRuntimeMacro.scratchDir)
package_names=$(node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(value.portablePackages.map(item => item.name).join(","));' "$preparation_report")
[ "$package_names" = "AxolotyWire,AxolotyObjectModel,AxolotyProtocol,AxolotyCoatyModels,AxolotyStaticRuntime" ] || {
    echo "FAIL: preparation report portable package order is invalid" >&2
    exit 1
}
AXOLOTY_WIRE_SOURCE_DIR=$(json_field portablePackages.0.sourcePath)
AXOLOTY_OBJECT_MODEL_SOURCE_DIR=$(json_field portablePackages.1.sourcePath)
AXOLOTY_PROTOCOL_SOURCE_DIR=$(json_field portablePackages.2.sourcePath)
AXOLOTY_COATY_MODELS_SOURCE_DIR=$(json_field portablePackages.3.sourcePath)
AXOLOTY_STATIC_RUNTIME_SOURCE_DIR=$(json_field portablePackages.4.sourcePath)
export AXOLOTY_WIRE_SOURCE_DIR AXOLOTY_OBJECT_MODEL_SOURCE_DIR AXOLOTY_PROTOCOL_SOURCE_DIR AXOLOTY_COATY_MODELS_SOURCE_DIR AXOLOTY_STATIC_RUNTIME_SOURCE_DIR
fixture=${AXOLOTY_EMBEDDED_CORE_FIXTURE:-$source_root/Tests/Support/fixtures/StaticIoActorEmbeddedConsumer.swift}
[ -f "$fixture" ] || {
    echo "FAIL: Embedded Swift consumer fixture is missing: $fixture" >&2
    exit 1
}

[ -d "$json_core_dir" ] || {
    echo "FAIL: resolved swift-json _JSONCore source is missing: $json_core_dir" >&2
    exit 1
}

compile_json_core() {
    set --
    for source in "$json_core_dir"/*.swift "$json_core_dir"/Parser/*.swift "$json_core_dir"/SIMD/*.swift; do
        [ -f "$source" ] || continue
        set -- "$@" "$source"
    done
    [ "$#" -gt 0 ] || {
        echo "FAIL: no _JSONCore source files found at $json_core_dir" >&2
        exit 1
    }

    echo "Compiling _JSONCore as Embedded Swift..."
    swiftc \
        -target riscv32-none-none-eabi \
        -swift-version 6 \
        -enable-experimental-feature Embedded \
        -enable-experimental-feature Lifetimes \
        -package-name IkigaJSON \
        -parse-as-library -Osize -wmo \
        -module-name _JSONCore \
        -emit-module -emit-module-path "$workdir/_JSONCore.swiftmodule" \
        -c "$@" \
        -o "$workdir/_JSONCore.o"
}

compile_module() {
    module_name=$1
    module_dir=$2
    shift 2

    set --
    for source in "$module_dir"/*.swift; do
        [ -f "$source" ] || continue
        set -- "$@" "$source"
    done
    [ "$#" -gt 0 ] || {
        echo "FAIL: no Swift sources found for $module_name at $module_dir" >&2
        exit 1
    }

    echo "Compiling $module_name as Embedded Swift..."
    if [ "$module_name" = AxolotyStaticRuntime ]; then
        swiftc \
            -target riscv32-none-none-eabi \
            -swift-version 6 \
            -enable-experimental-feature Embedded \
            -enable-experimental-feature Lifetimes \
            -parse-as-library -Osize -wmo \
            -warnings-as-errors \
            -module-name "$module_name" \
            -load-plugin-executable "$macro_tool#AxolotyStaticRuntimeMacrosImplementation" \
            -I "$workdir" \
            -emit-module -emit-module-path "$workdir/$module_name.swiftmodule" \
            -c "$@" \
            -o "$workdir/$module_name.o"
    else
        swiftc \
            -target riscv32-none-none-eabi \
            -swift-version 6 \
            -enable-experimental-feature Embedded \
            -enable-experimental-feature Lifetimes \
            -parse-as-library -Osize -wmo \
            -module-name "$module_name" \
            -I "$workdir" \
            -emit-module -emit-module-path "$workdir/$module_name.swiftmodule" \
            -c "$@" \
            -o "$workdir/$module_name.o"
    fi
}

compile_json_core
compile_module AxolotyWire "$AXOLOTY_WIRE_SOURCE_DIR"
compile_module AxolotyObjectModel "$AXOLOTY_OBJECT_MODEL_SOURCE_DIR"
compile_module AxolotyProtocol "$AXOLOTY_PROTOCOL_SOURCE_DIR"
compile_module AxolotyCoatyModels "$AXOLOTY_COATY_MODELS_SOURCE_DIR"
compile_module AxolotyStaticRuntime "$AXOLOTY_STATIC_RUNTIME_SOURCE_DIR"

link_probe="$source_root/Tests/Support/embedded/embedded-swift-link-probe.swift"
parser_probe="$source_root/Tests/Support/embedded/embedded-swift-parser-probe.swift"
host_shims="$source_root/Tests/Support/embedded/embedded-swift-host-shims.c"
for probe_source in "$link_probe" "$parser_probe" "$host_shims"; do
    [ -f "$probe_source" ] || {
        echo "FAIL: Embedded Swift probe source is missing: $probe_source" >&2
        exit 1
    }
done

echo "Compiling the AxolotyWire RISC-V link probe..."
swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -parse-as-library -Osize -wmo \
    -I "$workdir" \
    -c "$link_probe" \
    -o "$workdir/embedded-wire-link-probe.o"

echo "Compiling the real StaticIoActor Embedded consumer..."
swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -parse-as-library -Osize -wmo \
    -load-plugin-executable "$macro_tool#AxolotyStaticRuntimeMacrosImplementation" \
    -I "$workdir" \
    -c "$fixture" \
    -o "$workdir/StaticIoActorEmbeddedConsumer.o"

find_riscv_linker() {
    if [ -n "${AXOLOTY_RISCV_LINKER:-}" ]; then
        if [ -x "$AXOLOTY_RISCV_LINKER" ]; then
            printf '%s\n' "$AXOLOTY_RISCV_LINKER"
            return 0
        fi
        echo "FAIL: AXOLOTY_RISCV_LINKER is not executable: $AXOLOTY_RISCV_LINKER" >&2
        return 1
    fi

    swiftc_bin=$(CDPATH= cd -- "$(dirname -- "$(command -v swiftc)")" && pwd)
    for candidate in \
        "$swiftc_bin/ld.lld" \
        "$swiftc_bin/../lib/llvm/bin/ld.lld" \
        /usr/lib/swift/llvm/bin/ld.lld \
        /usr/local/swift/usr/bin/ld.lld \
        /usr/bin/ld.lld; do
        if [ -x "$candidate" ]; then
            # Preserve the ld.lld invocation name. Resolving this symlink to
            # the generic `lld` driver loses its Unix-linker mode.
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    linker_from_path=$(command -v ld.lld 2>/dev/null || true)
    if [ -n "$linker_from_path" ] && [ -x "$linker_from_path" ]; then
        printf '%s\n' "$linker_from_path"
        return 0
    fi
    echo "FAIL: no RISC-V-capable ld.lld found for the Core partial link" >&2
    return 1
}

echo "Partially linking the Core modules and consumer..."
riscv_linker=$(find_riscv_linker)
"$riscv_linker" -r \
    -o "$workdir/embedded-wire-linked.o" \
    "$workdir/embedded-wire-link-probe.o" \
    "$workdir/AxolotyWire.o" \
    "$workdir/_JSONCore.o"
wire_linked_size=$(wc -c < "$workdir/embedded-wire-linked.o")
echo "  AxolotyWire link probe: ${wire_linked_size} bytes"

"$riscv_linker" -r \
    -o "$workdir/embedded-core-linked.o" \
    "$workdir/StaticIoActorEmbeddedConsumer.o" \
    "$workdir/AxolotyStaticRuntime.o" \
    "$workdir/AxolotyCoatyModels.o" \
    "$workdir/AxolotyProtocol.o" \
    "$workdir/AxolotyObjectModel.o" \
    "$workdir/AxolotyWire.o" \
    "$workdir/_JSONCore.o"

linked_size=$(wc -c < "$workdir/embedded-core-linked.o")

echo "Running Embedded Swift parser behavior probe..."
host_target=$(swiftc -print-target-info | node -e 'let data=""; process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => process.stdout.write(JSON.parse(data).target.triple));')
swift_resource_dir=$(swiftc -print-target-info | node -e 'let data=""; process.stdin.on("data", chunk => data += chunk); process.stdin.on("end", () => process.stdout.write(JSON.parse(data).paths.runtimeResourcePath));')
unicode_archive="$swift_resource_dir/embedded/$host_target/libswiftUnicodeDataTables.a"
[ -f "$unicode_archive" ] || {
    echo "FAIL: Embedded Unicode archive not found for host target $host_target at $unicode_archive" >&2
    exit 1
}

set --
for source in "$json_core_dir"/*.swift "$json_core_dir"/Parser/*.swift "$json_core_dir"/SIMD/*.swift; do
    [ -f "$source" ] || continue
    set -- "$@" "$source"
done
[ "$#" -gt 0 ] || {
    echo "FAIL: no _JSONCore source files found for the host parser probe" >&2
    exit 1
}

swiftc \
    -target "$host_target" \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -package-name IkigaJSON \
    -parse-as-library -Osize -wmo \
    -module-name _JSONCore \
    -emit-module -c "$@" \
    -o "$workdir/JSONCore-host.o" \
    -emit-module-path "$workdir/_JSONCore.swiftmodule"
clang -c "$host_shims" -o "$workdir/embedded-host-shims.o"
swiftc \
    -target "$host_target" \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -enable-experimental-feature StrictConcurrency \
    -Osize -wmo \
    -I "$workdir" \
    "$AXOLOTY_WIRE_SOURCE_DIR"/*.swift "$parser_probe" \
    "$workdir/JSONCore-host.o" \
    "$workdir/embedded-host-shims.o" \
    "$unicode_archive" \
    -Xlinker -lm \
    -o "$workdir/embedded-parser-probe"
"$workdir/embedded-parser-probe"

echo "  Parser behavior: valid, missing-data, literal, number, and nesting mappings passed"
echo "EMBEDDED SWIFT CORE OK — five portable modules, StaticIoActor consumer, RISC-V link probe, and parser probe passed: ${linked_size} bytes"
