// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import ObservedObjectsSpike

@Suite
struct ReceiptTimeTests {
    @Test func expandsReceiptWithoutRedatingItAtDrain() {
        #expect(receiptTick(101, within: 100...120) == 101)
        #expect(receiptTick(99, within: 100...120) == nil)
        #expect(receiptTick(121, within: 100...120) == nil)
    }

    @Test func expandsReceiptAcrossWrap() {
        let lastTick = UInt64(UInt32.max)
        let window = (lastTick - 1)...(lastTick + 3)
        #expect(receiptTick(1, within: window) == lastTick + 2)
    }

    @Test func rejectsAnUnboundedReceiptWindow() {
        #expect(receiptTick(1, within: 0...(UInt64(Int32.max) + 1)) == nil)
    }
}
