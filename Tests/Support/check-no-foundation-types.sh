#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

# Ensures the types converted in #110 do not expose Foundation types
# (Data, Date, URL, Decimal, NSNull) in their public stored properties.
# This protects the Embedded Swift path tracked by #111 — Foundation
# types in the public shape would make a later mechanism swap a redesign
# rather than a migration.
#
# Scope: snapshot types, converted event types, SensorThings model types,
# JSONValue, and FilterOperand. ObjectFilterExpression's NSRegularExpression
# is an intentional Phase 2 exception (not in scope for this check).

files="
Source/Communication/Events/Snapshots/AdvertiseEventSnapshot.swift
Source/Communication/Events/Snapshots/CallEventSnapshot.swift
Source/Communication/Events/Snapshots/ChannelEventSnapshot.swift
Source/Communication/Events/Snapshots/CoatyObjectSnapshot.swift
Source/Communication/Events/Snapshots/DeadvertiseEventSnapshot.swift
Source/Communication/Events/Snapshots/DiscoverEventSnapshot.swift
Source/Communication/Events/Snapshots/EventSnapshot.swift
Source/Communication/Events/Snapshots/IoStateEventSnapshot.swift
Source/Communication/Events/Snapshots/IoValueEventSnapshot.swift
Source/Communication/Events/Snapshots/QueryEventSnapshot.swift
Source/Communication/Events/Snapshots/ResponseEventSnapshot.swift
Source/Communication/Events/Snapshots/SnapshotWirePayload.swift
Source/Communication/Events/Snapshots/UpdateEventSnapshot.swift
Source/Communication/Events/CallEvent.swift
Source/Communication/Events/ReturnEvent.swift
Source/Communication/Events/IoValueEvent.swift
Source/SensorThings/Sensor.swift
Source/SensorThings/Observation.swift
Source/SensorThings/FeatureOfInterest.swift
Source/Common/JSONValue.swift
Source/Model/FilterOperand.swift
"

found=0
for file in $files; do
    if grep -n 'public.*: Data\b\|public.*: Date\b\|public.*: URL\b\|public.*: Decimal\b\|public.*: NSNull\b\|public.*: Data?\|public.*: Date?\|public.*: URL?\|public.*: Decimal?\|public.*: NSNull?' "$file" 2>/dev/null; then
        echo "error: Foundation type found in public shape of $file (see above)" >&2
        found=1
    fi
done

if [ "$found" -ne 0 ]; then
    echo "Foundation types in public shape break the Embedded Swift path (#111)." >&2
    echo "Use String or other stdlib types instead." >&2
    exit 1
fi
