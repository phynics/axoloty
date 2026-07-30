// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release consumer exercising the communication event layer (issue #353).
//
// Anchors AdvertiseEvent and CommunicationManager so dead stripping cannot
// erase the communication subsystem. The binary size captures the incremental
// cost of the event types, snapshot metadata, and topic-building machinery
// beyond the wire-only baseline.

import Axoloty

let identity = Identity(name: "communication-consumer-anchor")
let event = try AdvertiseEvent.with(object: identity)
print("COMMUNICATION_CONSUMER_OK: \(type(of: event))")
