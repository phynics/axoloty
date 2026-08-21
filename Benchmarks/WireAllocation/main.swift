// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Dedicated host allocation-regression probe for the AxolotyWire borrowed
// decode + static routing hot path (issue #490).
//
// This executable performs ONLY a warmed steady-state decode/route pass, so a
// malloc-counting instrument (heaptrack) measures the hot path in isolation.
// The number of hot-path iterations is passed as the single argument, so the
// regression gate can compare allocation counts at two widely different
// iteration counts and reject any per-message allocation (which would scale
// the total count with the argument).
//
// Usage:
//   WireAllocation [iterations]   default 50_000 decode+route iterations
//
// It emits no per-iteration JSON; the check script wraps it in heaptrack.

import AxolotyWire
import AxolotyProtocol

@inline(never)
func hotPath(
    topicBuffer: UnsafePointer<UInt8>,
    topicLength: Int,
    payloadBuffer: UnsafePointer<UInt8>,
    payloadLength: Int,
    iterations: Int
) -> UInt32 {
    var sink: UInt32 = 0
    let router = try! EmbeddedMessageRouter()
    _ = router.subscribe(.associate) { _ in }
    for _ in 0..<iterations {
        let message = BorrowedMessage(
            topicBytes: topicBuffer, topicLength: topicLength,
            payloadBytes: payloadBuffer, payloadLength: payloadLength
        )
        // DTO decode through the borrowed reader.
        if (try? AssociateWireData(from: message.reader())) != nil { sink &+= 1 }
        // Synchronous static routing.
        router.dispatch(message)
    }
    return sink
}

let iterations = Int(CommandLine.arguments.dropFirst().first ?? "50000")!
let payload =
    "{\"ioSourceId\":\"33333333-3333-4333-8333-333333333333\",\"ioActorId\":\"33333333-3333-4333-8333-333333333333\",\"isExternalRoute\":true}"
let topic = "coaty/3/ns/ASC:filter/source-id"
let payloadBytes = Array(payload.utf8)
let topicBytes = Array(topic.utf8)

var total: UInt32 = 0
payloadBytes.withUnsafeBufferPointer { pb in
    topicBytes.withUnsafeBufferPointer { tb in
        // Warm-up pass (pay any one-time setup / first-touch COW before the
        // measured window so it cannot be mistaken for a per-iteration cost).
        _ = hotPath(
            topicBuffer: tb.baseAddress!, topicLength: tb.count,
            payloadBuffer: pb.baseAddress!, payloadLength: pb.count,
            iterations: 1_000
        )
        // Measured steady-state pass at the requested iteration count.
        total = hotPath(
            topicBuffer: tb.baseAddress!, topicLength: tb.count,
            payloadBuffer: pb.baseAddress!, payloadLength: pb.count,
            iterations: max(1, iterations)
        )
    }
}
// Keep the result live so the compiler cannot elide the loop.
if total == UInt32.max { print(total) }
