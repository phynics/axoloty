#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

# Firmware cross-build evidence belongs to axoloty-embedded. Core retains this
# portable object-model probe as a named release input.
root=$(cd "$(dirname "$0")/../.." && pwd)
AXOLOTY_G3_EVIDENCE_NAME=portable-evidence.json \
AXOLOTY_G3_EVIDENCE_NODE=g3-object-model-evidence-portable \
exec "$root/Spikes/BoundedObjectModelEvidence/check-host.sh" "$@"
