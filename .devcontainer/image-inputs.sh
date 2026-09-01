#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

# Keep this list in lock-step with the immutable/toolchain COPY instructions
# in Dockerfile. Project source and tests are mounted at runtime and must not
# affect image freshness.
paths=(
    .devcontainer/Dockerfile
    .devcontainer/image-inputs.sh
    .devcontainer/ax
    .devcontainer/axoloty-tool
    .devcontainer/axoloty-mcp
    .devcontainer/axoloty-cli
    .dockerignore
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
