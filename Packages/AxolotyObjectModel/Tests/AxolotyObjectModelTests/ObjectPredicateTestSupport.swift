// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

@Suite("Object predicate behavior")
struct ObjectPredicateTests {}

func predicateSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

func predicateObject(_ value: StaticString) throws -> BoundedDynamicObject<512, 8> {
    try BoundedDynamicObject<512, 8>(decoding: predicateSlice(value))
}
