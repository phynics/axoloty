// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

extension ObjectPredicateTests {
@Test func exactDecimalsAndNegativeZeroCompareWithoutDouble() throws {
    let equality = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"value\",[7,1.0]]}"))
    let zero = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"value\",[7,-0.0]]}"))
    let object = try predicateObject("{\"value\":1e0}")
    let equalityMatched = equality.matches(object: object)
    let zeroMatched = zero.matches(object: object)
    #expect(equalityMatched)
    #expect(zeroMatched == false)
}

@Test func arbitraryExponentOrderingRemainsExact() throws {
    let equal = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[7,1e1000000]]}"))
    let different = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[7,1e1000001]]}"))
    let greater = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[2,1e1000000]]}"))
    let negative = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[2,-1e-1000000]]}"))
    let object = try predicateObject("{\"v\":1e1000000}")
    let largerObject = try predicateObject("{\"v\":1e1000001}")
    let negativeObject = try predicateObject("{\"v\":-1e-1000001}")
    let equalMatched = equal.matches(object: object)
    let differentMatched = different.matches(object: object)
    let greaterMatched = greater.matches(object: largerObject)
    let negativeMatched = negative.matches(object: negativeObject)
    #expect(equalMatched)
    #expect(!differentMatched)
    #expect(greaterMatched)
    #expect(negativeMatched)
}

@Test func stringOrderingUsesScalarLexicographicOrder() throws {
    let greater = try ObjectPredicate<64, 4, 4, 128>(path: "name", expression: .greaterThan(.string("aa")))
    let object = try predicateObject("{\"name\":\"b\"}")
    let matched = greater.matches(object: object)
    #expect(matched)
}

@Test func maximumValidWireStringDoesNotTruncate() throws {
    let predicate = try ObjectPredicate<8, 4, 2, 1024>(path: "name", expression: .equals(.string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
    let object = try BoundedDynamicObject<1024, 8>(decoding: predicateSlice("{\"name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"))
    let matched = predicate.matches(object: object)
    #expect(matched)

    let oversized = "{\"name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
    #expect(throws: ObjectError.self) {
        let bytes = Array(oversized.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            _ = try BoundedDynamicObject<1024, 8>(decoding: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count))
        }
    }
}
}
