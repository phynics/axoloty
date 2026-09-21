#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

# Keep this path stable until the firmware repository owns the cross-build
# evidence. The Core fallback measures the portable object model only.
root=$(cd "$(dirname "$0")/../.." && pwd)
AXOLOTY_G3_EVIDENCE_NAME=portable-evidence.json \
AXOLOTY_G3_EVIDENCE_NODE=g3-object-model-evidence-embedded \
exec "$root/Spikes/BoundedObjectModelEvidence/check-host.sh" "$@"
