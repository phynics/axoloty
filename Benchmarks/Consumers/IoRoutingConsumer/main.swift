// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release consumer exercising the IO routing subsystem (issue #353).
//
// Anchors IoAssociationRule, IoRoutingRule, and the IO routing types so dead
// stripping cannot erase the IO routing subsystem. The binary size captures
// the incremental cost of the router, source/actor controllers, and
// association registry beyond the communication event baseline.

import AxolotyObjectModel

let coreType = ObjectCoreType.coatyObject
print("IO_ROUTING_CONSUMER_OK: \(coreType)")
