#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
rm -rf .build/jsoncore-package .build/checkouts .build/swift-json
mkdir -p .build
git clone --quiet https://github.com/orlandos-nl/swift-json.git .build/swift-json
git -C .build/swift-json checkout --quiet 216e30b22ef3c4180e126f284a4c62d51a1c1049
mkdir -p .build/jsoncore-package
cp -R .build/swift-json/Sources .build/jsoncore-package/
python3 - .build/jsoncore-package <<'PY'
from pathlib import Path
p=Path(__import__('sys').argv[1])/'Package.swift'
p.write_text('''// swift-tools-version:6.3\nimport PackageDescription\nlet package = Package(name: "swift-json", products: [.library(name: "IkigaJSONCore", targets: ["_JSONCore"])], targets: [.target(name: "_JSONCore", swiftSettings: [.enableExperimentalFeature("Lifetimes")])])\n''')
PY
repo=$(cd "$root/../.." && pwd)
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$root/.build" SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
"$repo/.devcontainer/run.sh" swift run --package-path "/workspace/Spikes/StrictJSONCoreAdapter" \
    --disable-automatic-resolution StrictJSONCoreAdapterSpike
mkdir -p .build/embedded
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman} IMAGE=${IMAGE:-axoloty-dev} \
BUILD_DIR="$root/.build" SPM_CACHE_DIR="${SPM_CACHE_DIR:-$HOME/.cache/coaty-swift/swiftpm/swift-6.3-linux}" \
"$repo/.devcontainer/run.sh" bash -lc '
set -eu
rm -f /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/*
swiftc -target riscv32-none-none-eabi -enable-experimental-feature Embedded \
  -enable-experimental-feature Lifetimes -enable-experimental-feature StrictConcurrency \
  -parse-as-library -wmo -module-name _JSONCore -package-name IkigaJSON \
  -emit-module -emit-module-path /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/_JSONCore.swiftmodule \
  -c -o /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/JSONCore.o \
  /workspace/Spikes/StrictJSONCoreAdapter/.build/swift-json/Sources/_JSONCore/*.swift \
  /workspace/Spikes/StrictJSONCoreAdapter/.build/swift-json/Sources/_JSONCore/Parser/*.swift \
  /workspace/Spikes/StrictJSONCoreAdapter/.build/swift-json/Sources/_JSONCore/SIMD/*.swift
swiftc -target riscv32-none-none-eabi -enable-experimental-feature Embedded \
  -enable-experimental-feature Lifetimes -enable-experimental-feature StrictConcurrency \
  -parse-as-library -wmo -I /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded \
  -module-name StrictJSONCoreAdapter -package-name IkigaJSON -c \
  -o /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/StrictJSONCoreAdapter.o \
  /workspace/Spikes/StrictJSONCoreAdapter/Sources/StrictJSONCoreAdapter.swift
linker=/usr/lib/swift/llvm/bin/ld.lld
if [ ! -x "$linker" ]; then linker=/usr/bin/ld.lld; fi
"$linker" -r \
  -o /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/linked.o \
  /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/JSONCore.o \
  /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/StrictJSONCoreAdapter.o
stat -c "Embedded %s %n" /workspace/Spikes/StrictJSONCoreAdapter/.build/embedded/*
'
