#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

# Keep this list in lock-step with the COPY instructions in Dockerfile.  The
# output is a stable sha256sum input stream for both CI and local tooling.
paths=(
    .devcontainer/Dockerfile
    .devcontainer/image-inputs.sh
    .dockerignore
    Tools/Package.swift
    Tools/AxolotyTooling
    Tools/axoloty-tool
    Package.swift
    Package.resolved
    Packages
    Source
    Tests
    Benchmarks
    Tools
)

for path in "${paths[@]}"; do
    if [[ -f "$path" ]]; then
        printf '%s\0' "$path"
    else
        find "$path" -type f -print0
    fi
done | sort -z | while IFS= read -r -d '' path; do
    sha256sum "$path"
done
