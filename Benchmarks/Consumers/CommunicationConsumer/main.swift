// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release consumer exercising the modern protocol layer.
//
// The binary size captures the incremental cost of the shared protocol
// routing-key and capability machinery beyond the wire-only baseline.

import AxolotyProtocol

let key = try ProtocolRoutingKey(capability: .advertise, sourceID: .zero)
print("COMMUNICATION_CONSUMER_OK: \(key.capability)")
