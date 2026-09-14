#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Resolve the caller-selected Axoloty Core checkout for the firmware build.
# This is intentionally a shell library: the firmware wrapper owns build
# storage and invokes this boundary before ESP-IDF is configured.

set -eu

embedded_core_error() {
    echo "error: $*" >&2
    return 1
}

embedded_core_resolve() {
    source_dir=${AXOLOTY_SOURCE_DIR:-}
    [ -n "$source_dir" ] || embedded_core_error \
        "AXOLOTY_SOURCE_DIR is required; supply a Core checkout"
    case "$source_dir" in
        /*) ;;
        *) embedded_core_error \
            "AXOLOTY_SOURCE_DIR must be an absolute path: $source_dir" ;;
    esac
    command -v realpath >/dev/null 2>&1 || embedded_core_error \
        "realpath is required to validate AXOLOTY_SOURCE_DIR"

    core_dir=$(realpath -e -- "$source_dir" 2>/dev/null) || embedded_core_error \
        "AXOLOTY_SOURCE_DIR does not exist: $source_dir"
    [ -d "$core_dir" ] || embedded_core_error \
        "AXOLOTY_SOURCE_DIR is not a directory: $source_dir"
    [ "$source_dir" = "$core_dir" ] || embedded_core_error \
        "AXOLOTY_SOURCE_DIR must be canonical: $source_dir resolves to $core_dir"

    command -v git >/dev/null 2>&1 || embedded_core_error \
        "git is required to identify the selected Core checkout"
    git_root=$(git -C "$core_dir" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$git_root" ] || embedded_core_error \
        "AXOLOTY_SOURCE_DIR is not a Git checkout: $core_dir"
    git_root=$(realpath -e -- "$git_root")
    [ "$git_root" = "$core_dir" ] || embedded_core_error \
        "AXOLOTY_SOURCE_DIR must be the Git checkout root: $core_dir"

    resolve_core_child() {
        variable_name=$1
        relative_path=$2
        package_name=$3
        expected_files=$4
        child_path="$core_dir/$relative_path"
        child_dir=$(realpath -e -- "$child_path" 2>/dev/null) || embedded_core_error \
            "$variable_name does not exist: $child_path"
        case "$child_dir" in
            "$core_dir"/*) ;;
            *) embedded_core_error \
                "$variable_name escapes AXOLOTY_SOURCE_DIR through a symlink: $child_path -> $child_dir" ;;
        esac
        [ -d "$child_dir" ] || embedded_core_error \
            "$variable_name is not a directory: $child_dir"
        package_dir="$core_dir/Packages/$package_name"
        [ -f "$package_dir/Package.swift" ] || embedded_core_error \
            "$package_name package manifest is missing: $package_dir/Package.swift"
        grep -Fq "name: \"$package_name\"" "$package_dir/Package.swift" || embedded_core_error \
            "$package_name package manifest has an unexpected identity: $package_dir/Package.swift"
        for expected_file in $expected_files; do
            [ -f "$child_dir/$expected_file" ] || embedded_core_error \
                "$variable_name expected source file is missing: $child_dir/$expected_file"
        done
        case "$variable_name" in
            AXOLOTY_WIRE_SOURCE_DIR)
                AXOLOTY_WIRE_SOURCE_DIR="$child_dir"
                export AXOLOTY_WIRE_SOURCE_DIR
                ;;
            AXOLOTY_OBJECT_MODEL_SOURCE_DIR)
                AXOLOTY_OBJECT_MODEL_SOURCE_DIR="$child_dir"
                export AXOLOTY_OBJECT_MODEL_SOURCE_DIR
                ;;
            AXOLOTY_PROTOCOL_SOURCE_DIR)
                AXOLOTY_PROTOCOL_SOURCE_DIR="$child_dir"
                export AXOLOTY_PROTOCOL_SOURCE_DIR
                ;;
            AXOLOTY_COATY_MODELS_SOURCE_DIR)
                AXOLOTY_COATY_MODELS_SOURCE_DIR="$child_dir"
                export AXOLOTY_COATY_MODELS_SOURCE_DIR
                ;;
            AXOLOTY_STATIC_RUNTIME_SOURCE_DIR)
                AXOLOTY_STATIC_RUNTIME_SOURCE_DIR="$child_dir"
                export AXOLOTY_STATIC_RUNTIME_SOURCE_DIR
                ;;
            *) embedded_core_error "unsupported Core source variable: $variable_name" ;;
        esac
    }

    resolve_core_child AXOLOTY_WIRE_SOURCE_DIR \
        Packages/AxolotyWire/Sources/AxolotyWire AxolotyWire \
        'BorrowedMessage.swift TopicView.swift WireReader.swift WireWriter.swift'
    resolve_core_child AXOLOTY_OBJECT_MODEL_SOURCE_DIR \
        Packages/AxolotyObjectModel/Sources/AxolotyObjectModel AxolotyObjectModel \
        'ObjectEnvelope.swift ObjectSchema.swift'
    resolve_core_child AXOLOTY_PROTOCOL_SOURCE_DIR \
        Packages/AxolotyProtocol/Sources/AxolotyProtocol AxolotyProtocol \
        'CoatyCore3.swift ProtocolFrame.swift ProtocolProcessor.swift'
    resolve_core_child AXOLOTY_COATY_MODELS_SOURCE_DIR \
        Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels AxolotyCoatyModels \
        'CoatyModels.swift'
    resolve_core_child AXOLOTY_STATIC_RUNTIME_SOURCE_DIR \
        Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime AxolotyStaticRuntime \
        'StaticRuntime.swift StaticIoActor.swift StaticIoRegistry.swift StaticIoRuntime.swift'

    AXOLOTY_SOURCE_DIR=$core_dir
    export AXOLOTY_SOURCE_DIR
    AXOLOTY_CORE_SHA=$(git -C "$core_dir" rev-parse --verify HEAD^{commit})
    if [ "${#AXOLOTY_CORE_SHA}" -ne 40 ]; then
        embedded_core_error "could not determine a 40-character AXOLOTY_CORE_SHA for $core_dir"
    fi
    case "$AXOLOTY_CORE_SHA" in
        *[!0-9a-f]*) embedded_core_error "AXOLOTY_CORE_SHA is not lowercase hexadecimal: $AXOLOTY_CORE_SHA" ;;
    esac
    export AXOLOTY_CORE_SHA
    if [ -n "$(git -C "$core_dir" status --porcelain --untracked-files=normal)" ]; then
        AXOLOTY_CORE_DIRTY=1
    else
        AXOLOTY_CORE_DIRTY=0
    fi
    export AXOLOTY_CORE_DIRTY
}

if [ "${AXOLOTY_EMBEDDED_CORE_NO_EXEC:-0}" != 1 ]; then
    embedded_core_resolve
    printf 'AXOLOTY_SOURCE_DIR=%s\n' "$AXOLOTY_SOURCE_DIR"
    printf 'AXOLOTY_CORE_SHA=%s\n' "$AXOLOTY_CORE_SHA"
    printf 'AXOLOTY_CORE_DIRTY=%s\n' "$AXOLOTY_CORE_DIRTY"
fi
