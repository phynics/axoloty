// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// The borrowed field index stores slots in a fixed `InlineArray`. `InlineArray`
/// requires a literal count, so nothing in the type system ties that count to
/// ``WireBufferConfig/maxIndexedFields``. This pins the two together so the
/// configured public limit and the physical storage cannot drift apart.
@Suite("Wire field index storage")
struct WireFieldIndexStorageTests {
    @Test("The slot storage capacity matches the configured field limit")
    func storageCapacityMatchesConfiguredLimit() {
        #expect(WireFieldIndex().slots.count == WireBufferConfig.maxIndexedFields)
    }
}
