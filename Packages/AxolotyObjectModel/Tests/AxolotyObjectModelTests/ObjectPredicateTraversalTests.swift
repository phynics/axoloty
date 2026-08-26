// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

extension ObjectPredicateTests {
@Test func borrowedWireValueViewsRemainScopedToTraversal() throws {
    var count = 0
    var allNonEmpty = true
    try predicateSlice("[1,{\"v\":2},null]").withBorrowedArrayElements { value in
        count += 1
        allNonEmpty = allNonEmpty && value.length > 0
    }
    #expect(count == 3)
    #expect(allNonEmpty)
}
}
