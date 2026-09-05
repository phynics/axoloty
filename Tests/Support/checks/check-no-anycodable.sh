#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

# Ensures AnyCodable does not reappear in Source/ after its removal in #110.
# AnyCodable was replaced by the internal JSONValue type and raw JSON String
# storage. See #110 for the full migration record.

if grep -rn 'AnyCodable' Source --include='*.swift'; then
    echo "" >&2
    echo "error: AnyCodable references found in Source/ (see above)" >&2
    echo "AnyCodable was removed in #110; use JSONValue or raw JSON String instead." >&2
    exit 1
fi
