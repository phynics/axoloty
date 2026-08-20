// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import BoundedPortableRuntime

private struct Value {
    var nested: InlineArray<2, UInt16> = InlineArray(repeating: 0)
}

nonisolated(unsafe) private var receivedHandle: UInt32 = 0
private func callback(_ handle: UInt32) { receivedHandle = handle }

@Test("inline table saturates exactly and rejects stale tokens")
func inlineTableSaturation() {
    var table = InlineSlotTable<Value, 4>()
    let first = table.insert(Value())!
    #expect(table.update(first) { $0.nested[0] = 9 })
    #expect(table.insert(Value()) != nil)
    #expect(table.insert(Value()) != nil)
    #expect(table.insert(Value()) != nil)
    #expect(table.insert(Value()) == nil)
    #expect(table.count == 4)
    let removed = table.remove(first)
    let stale = !table.update(first) { _ in }
    #expect(removed)
    #expect(stale)
}

@Test("parser uses one algorithm for embedded and host workspaces")
func parserWorkspaceParity() {
    let payload = InlineParserInput<512>(repeating: 1, count: 512)
    var embedded = ParserWorkspace<520>()
    var host = HostParserWorkspace(capacity: 4096)
    let embeddedAccepted = embedded.parse(payload)
    let hostAccepted = host.parse(payload)
    let sameTrace = embedded.snapshot() == host.snapshot()
    let oversized = InlineParserInput<513>(repeating: 1, count: 513)
    let rejected = !embedded.parse(oversized)
    #expect(embeddedAccepted)
    #expect(hostAccepted)
    #expect(sameTrace)
    #expect(rejected)
}

@Test("handler entries carry numeric context only")
func handlerContext() {
    receivedHandle = 0
    var handlers = HandlerTable<1>()
    let token = handlers.register(HandlerEntry(function: callback, context: HandlerContext(handle: 17)))!
    let dispatched = handlers.dispatch(token)
    let unregistered = handlers.unregister(token)
    let stale = !handlers.dispatch(token)
    #expect(dispatched)
    #expect(receivedHandle == 17)
    #expect(unregistered)
    #expect(stale)

    let inactive = handlers.register(
        HandlerEntry(function: callback, context: HandlerContext(handle: 18, active: false))
    )
    #expect(inactive == nil)
}

@Test("deterministic randomized operations preserve token generations")
func randomizedTokenOperations() {
    var table = InlineSlotTable<Value, 16>()
    var live: [UInt64] = []
    var seed: UInt64 = 0x41584f4c4f5459
    for _ in 0..<2_000 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        switch seed % 3 {
        case 0:
            if let token = table.insert(Value()) { live.append(token) }
        case 1 where !live.isEmpty:
            let token = live.removeFirst()
            let removed = table.remove(token)
            let stale = !table.update(token) { _ in }
            #expect(removed)
            #expect(stale)
        default:
            if let token = live.first {
                let updated = table.update(token) { $0.nested[0] &+= 1 }
                #expect(updated)
            }
        }
    }
    #expect(table.count == live.count)
}
