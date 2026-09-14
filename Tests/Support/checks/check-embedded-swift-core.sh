#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Compile and partially link the portable Axoloty Core profile as Embedded
# Swift. This gate deliberately owns no firmware project, SDK, broker, or
# hardware state. It proves the dependency order used by a downstream Core
# consumer and expands a real StaticIoActor declaration with the production
# macro plugin.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
support_dir="$root_dir/Tests/Support/embedded"

command -v swift >/dev/null 2>&1 || {
    echo "FAIL: swift is required to prepare the Embedded Swift Core tools" >&2
    exit 1
}
command -v swiftc >/dev/null 2>&1 || {
    echo "FAIL: swiftc is required for the Embedded Swift Core check" >&2
    exit 1
}
command -v realpath >/dev/null 2>&1 || {
    echo "FAIL: realpath is required for the Embedded Swift Core check" >&2
    exit 1
}

# The selected Core checkout is an explicit boundary. The default is useful
# for the repository's ordinary check, while callers may point this gate at a
# separate clean checkout or worktree.
AXOLOTY_SOURCE_DIR=${AXOLOTY_SOURCE_DIR:-$root_dir}
export AXOLOTY_SOURCE_DIR

# Keep all generated compiler and macro state in a caller-owned temporary
# tree. In particular, do not use the firmware build directory or a package's
# implicit .build directory for this Core-only proof.
scratch_parent=${AXOLOTY_EMBEDDED_CORE_CHECK_DIR:-${TMPDIR:-/tmp}/axoloty-embedded-core}
case "$scratch_parent" in
    /*) ;;
    *)
        echo "FAIL: AXOLOTY_EMBEDDED_CORE_CHECK_DIR must be absolute: $scratch_parent" >&2
        exit 1
        ;;
esac
mkdir -p -- "$scratch_parent"
workdir=$(mktemp -d "$scratch_parent/run.XXXXXX")
trap 'rm -rf -- "$workdir"' EXIT HUP INT TERM

compiler_dir="$workdir/compiler"
macro_scratch=${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR:-$workdir/macro-tools}
mkdir -p -- "$compiler_dir"
AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR=$macro_scratch
export AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR

AXOLOTY_EMBEDDED_CORE_TOOLS_NO_EXEC=1 . "$support_dir/prepare-embedded-core-tools.sh"
embedded_core_prepare_tools "$compiler_dir" "$support_dir/resolve-embedded-core.sh"

source_root=$AXOLOTY_SOURCE_DIR
fixture=${AXOLOTY_EMBEDDED_CORE_FIXTURE:-$source_root/Tests/Support/fixtures/StaticIoActorEmbeddedConsumer.swift}
[ -f "$fixture" ] || {
    echo "FAIL: Embedded Swift consumer fixture is missing: $fixture" >&2
    exit 1
}

json_core_dir=$AXOLOTY_JSON_CORE_SOURCE_DIR
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
            -load-plugin-executable "$AXOLOTY_STATIC_RUNTIME_MACRO_TOOL#AxolotyStaticRuntimeMacrosImplementation" \
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

echo "Compiling the real StaticIoActor Embedded consumer..."
swiftc \
    -target riscv32-none-none-eabi \
    -swift-version 6 \
    -enable-experimental-feature Embedded \
    -enable-experimental-feature Lifetimes \
    -parse-as-library -Osize -wmo \
    -load-plugin-executable "$AXOLOTY_STATIC_RUNTIME_MACRO_TOOL#AxolotyStaticRuntimeMacrosImplementation" \
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
    -o "$workdir/embedded-core-linked.o" \
    "$workdir/StaticIoActorEmbeddedConsumer.o" \
    "$workdir/AxolotyStaticRuntime.o" \
    "$workdir/AxolotyCoatyModels.o" \
    "$workdir/AxolotyProtocol.o" \
    "$workdir/AxolotyObjectModel.o" \
    "$workdir/AxolotyWire.o" \
    "$workdir/_JSONCore.o"

linked_size=$(wc -c < "$workdir/embedded-core-linked.o")
echo "EMBEDDED SWIFT CORE OK — five portable modules, _JSONCore, and StaticIoActor consumer linked: ${linked_size} bytes"
