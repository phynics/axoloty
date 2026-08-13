// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

// Proves the wire symbols are reachable from a package that does not depend
// on the Axoloty host runtime, and gives the distribution gate a stable
// execution marker after the executable has linked.
print("AXOLOTY_WIRE_STANDALONE_CONSUMER_OK")
_ = UUID16.zero
