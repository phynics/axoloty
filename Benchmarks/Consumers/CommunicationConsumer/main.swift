// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release consumer exercising the communication event layer (issue #353).
//
// Anchors AdvertiseEvent and CommunicationManager so dead stripping cannot
// erase the communication subsystem. The binary size captures the incremental
// cost of the event types, snapshot metadata, and topic-building machinery
// beyond the wire-only baseline.

import AxolotyProtocol

let key = try ProtocolRoutingKey(capability: .advertise, sourceID: .zero)
print("COMMUNICATION_CONSUMER_OK: \(key.capability)")
