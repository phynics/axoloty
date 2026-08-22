// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

private func predicateSlice(_ value: StaticString) -> ByteSlice {
    ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
}

private func predicateObject(_ value: StaticString) throws -> BoundedDynamicObject<512, 8> {
    try BoundedDynamicObject<512, 8>(decoding: predicateSlice(value))
}

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

@Test func everyCoatyOperatorCodeDecodesAndMatches() throws {
    let cases: [(StaticString, Bool)] = [
        ("{\"conditions\":[\"v\",[0,2]]}" , false),
        ("{\"conditions\":[\"v\",[1,2]]}" , true),
        ("{\"conditions\":[\"v\",[2,2]]}" , false),
        ("{\"conditions\":[\"v\",[3,2]]}" , true),
        ("{\"conditions\":[\"v\",[4,2,3]]}" , true),
        ("{\"conditions\":[\"v\",[5,2,3]]}" , false),
        ("{\"conditions\":[\"v\",[6,\"2\"]]}", false),
        ("{\"conditions\":[\"v\",[7,2]]}" , true),
        ("{\"conditions\":[\"v\",[8,3]]}" , true),
        ("{\"conditions\":[\"v\",[9]]}" , true),
        ("{\"conditions\":[\"missing\",[10]]}" , true),
        ("{\"conditions\":[\"v\",[11,2]]}" , true),
        ("{\"conditions\":[\"v\",[12,3]]}" , true),
        ("{\"conditions\":[\"v\",[13,[1,2]]]}" , true),
        ("{\"conditions\":[\"v\",[14,[1,3]]]}" , true),
    ]
    for (filter, expected) in cases {
        let predicate = try ObjectPredicate<64, 8, 8, 512>(decoding: predicateSlice(filter))
        let object = try predicateObject("{\"v\":2}")
        let matched = predicate.matches(object: object)
        #expect(matched == expected)
    }
}

@Test func nestedGroupsPathsAndEscapedKeysMatch() throws {
    let filter = predicateSlice("{\"conditions\":{\"or\":[[\"nested.value\",[7,2]],[[\"a.b\"],[7,3]] ]}}")
    let predicate = try ObjectPredicate<128, 16, 8, 512>(decoding: filter)
    let object = try predicateObject("{\"nested\":{\"value\":2},\"a.b\":3}")
    let matched = predicate.matches(object: object)
    #expect(matched)
}

@Test func directConditionAndConditionSetShapesMatchCoatyWire() throws {
    let direct = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"v\",[7,2]]}"))
    let grouped = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice("{\"conditions\":{\"and\":[[\"v\",[7,2]],[\"present\",[9]]]}}"))
    let object = try predicateObject("{\"v\":2,\"present\":null}")
    let directMatched = direct.matches(object: object)
    let groupedMatched = grouped.matches(object: object)
    #expect(directMatched)
    #expect(groupedMatched)
}

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
            _ = try BoundedDynamicObject<1024, 8>(decoding: ByteSlice(
                bytes: buffer.baseAddress!, length: buffer.count
            ))
        }
    }
}

@Test func containsAndMembershipAreRecursiveAndOrderIndependent() throws {
    let contains = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[\"value\",[11,{\"b\":[2],\"a\":1}]]}"))
    let membership = try ObjectPredicate<128, 4, 8, 512>(decoding: predicateSlice("{\"conditions\":[\"value\",[13,[{\"a\":1,\"b\":[2]}]]]}"))
    let object = try predicateObject("{\"value\":{\"a\":1,\"b\":[2,3],\"extra\":true}}")
    let membershipObject = try predicateObject("{\"value\":{\"a\":1,\"b\":[2]}}")
    let containsMatched = contains.matches(object: object)
    let membershipMatched = membership.matches(object: membershipObject)
    #expect(containsMatched)
    #expect(membershipMatched)
}

@Test func likeUsesPercentUnderscoreAndEscapes() throws {
    let like = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"name\",[6,\"a_%\"]]}"))
    let object = try predicateObject("{\"name\":\"abc\"}")
    let likeMatched = like.matches(object: object)
    #expect(likeMatched)

    // The JSON `\\\\%` spelling decodes to a LIKE escape plus a literal `%`.
    let escaped = try ObjectPredicate<128, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"name\",[6,\"a\\\\%b\"]]}"))
    let escapedObject = try predicateObject("{\"name\":\"a%b\"}")
    let escapedMatched = escaped.matches(object: escapedObject)
    #expect(escapedMatched)
}

@Test func failedAppendConditionIsAtomic() throws {
    var predicate = try ObjectPredicate<4, 2, 2, 16>(path: "value", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) {
        try predicate.appendCondition(path: "a", expression: .equals(.string("this value cannot fit")))
    }
    let object = try predicateObject("{\"value\":1,\"a\":\"this value cannot fit\"}")
    let matched = predicate.matches(object: object)
    #expect(matched)
}

@Test func malformedWirePredicatesAreRejected() throws {
    let malformed: [StaticString] = [
        ("{\"conditions\":[\"v\",[99,1]]}"),
        ("{\"conditions\":[\"v\",[9,1]]}"),
        ("{\"conditions\":[\"v\",[4,1]]}"),
        ("{\"conditions\":[\"a..b\",[7,1]]}"),
        ("{\"conditions\":[1,[7,1]]}"),
        ("{\"conditions\":[\"v\",[13,1]]}"),
    ]
    for value in malformed {
        #expect(throws: ObjectError.self) {
            _ = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice(value))
        }
    }
}

@Test func malformedConditionSetsMatchObjectFilterCodableRules() throws {
    let malformed: [StaticString] = [
        ("{\"conditions\":{}}"),
        ("{\"conditions\":{\"xor\":[]}}"),
        ("{\"conditions\":{\"and\":[],\"or\":[]}}"),
    ]
    for value in malformed {
        #expect(throws: ObjectError.self) {
            _ = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice(value))
        }
    }
}

@Test func absentConditionsRetainsCoatyMatchAllSemantics() throws {
    let predicate = try ObjectPredicate<16, 2, 2, 64>(decoding: predicateSlice("{}"))
    let object = try predicateObject("{\"unfiltered\":true}")
    let matched = predicate.matches(object: object)
    #expect(matched)
}

@Test func encodeDecodeRoundTripsDirectAndGroupedPredicates() throws {
    let direct = try ObjectPredicate<64, 4, 4, 256>(
        decoding: predicateSlice("{\"conditions\":[\"value\",[7,1.00]]}")
    )
    let grouped = try ObjectPredicate<128, 8, 8, 512>(
        decoding: predicateSlice("{\"conditions\":{\"or\":[[\"value\",[7,1.00]],[\"missing\",[9]]]}}")
    )
    var output = [UInt8](repeating: 0, count: 1024)
    let roundTrips = try output.withUnsafeMutableBufferPointer { buffer -> (Bool, Bool) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try direct.encode(to: &writer)
        let directBytes = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decodedDirect = try ObjectPredicate<64, 4, 4, 256>(decoding: directBytes)
        let directObject = try predicateObject("{\"value\":1e0}")
        let directMatched = decodedDirect.matches(object: directObject)

        writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try grouped.encode(to: &writer)
        let groupedBytes = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decodedGrouped = try ObjectPredicate<128, 8, 8, 512>(decoding: groupedBytes)
        let groupedObject = try predicateObject("{\"value\":1e0}")
        let groupedMatched = decodedGrouped.matches(object: groupedObject)
        return (directMatched, groupedMatched)
    }
    #expect(roundTrips.0)
    #expect(roundTrips.1)
}

@Test func rootOrGroupRetainsCanonicalShape() throws {
    let predicate = try ObjectPredicate<128, 8, 8, 512>(
        decoding: predicateSlice("{\"conditions\":{\"or\":[[\"value\",[7,1]],[\"missing\",[9]]]}}")
    )
    var output = [UInt8](repeating: 0, count: 256)
    let encoded = try output.withUnsafeMutableBufferPointer { buffer -> ByteSlice in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try predicate.encode(to: &writer)
        return ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
    }
    #expect(encoded.equals("{\"conditions\":{\"or\":[[\"value\",[7,1]],[\"missing\",[9]]]}}"))
}

@Test func escapedPathSegmentsSurviveCanonicalRoundTrip() throws {
    let predicate = try ObjectPredicate<64, 8, 4, 256>(
        decoding: predicateSlice("{\"conditions\":[[\"a\\u002eb\"],[7,1]]}")
    )
    var output = [UInt8](repeating: 0, count: 256)
    let result = try output.withUnsafeMutableBufferPointer { buffer -> (Bool, Bool) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try predicate.encode(to: &writer)
        let encoded = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decoded = try ObjectPredicate<64, 8, 4, 256>(decoding: encoded)
        let object = try predicateObject("{\"a.b\":1}")
        return (
            encoded.equals("{\"conditions\":[[\"a.b\"],[7,1]]}"),
            decoded.matches(object: object)
        )
    }
    #expect(result.0)
    #expect(result.1)
}

@Test func matchAllEncodingAndWriterCapacityAreAtomic() throws {
    let matchAll = ObjectPredicate<16, 2, 2, 64>()
    var output = [UInt8](repeating: 0, count: 8)
    let encoded = try output.withUnsafeMutableBufferPointer { buffer -> Int in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try matchAll.encode(to: &writer)
        return writer.position
    }
    #expect(encoded == 2)

    let predicate = try ObjectPredicate<64, 4, 4, 256>(
        path: "value", expression: .equals(.number("123456789"))
    )
    var tiny = [UInt8](repeating: 0xA5, count: 4)
    let failure = tiny.withUnsafeMutableBufferPointer { buffer -> (Bool, Int) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        do {
            try predicate.encode(to: &writer)
            return (false, writer.position)
        } catch {
            return (true, writer.position)
        }
    }
    #expect(failure.0)
    #expect(failure.1 == 0)
}

@Test func eachInlineCapacityFailurePreservesPreviousProgram() throws {
    let object = try predicateObject("{\"a\":1,\"b\":2}")

    var nodes = try ObjectPredicate<2, 4, 4, 128>(path: "a", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) { try nodes.appendCondition(path: "b", expression: .equals(.number("2"))) }
    let nodesMatched = nodes.matches(object: object)
    #expect(nodesMatched)

    var paths = try ObjectPredicate<4, 1, 4, 128>(path: "a", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) { try paths.appendCondition(path: "b", expression: .equals(.number("2"))) }
    let pathsMatched = paths.matches(object: object)
    #expect(pathsMatched)

    var literals = try ObjectPredicate<4, 4, 1, 128>(path: "a", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) { try literals.appendCondition(path: "b", expression: .equals(.number("2"))) }
    let literalsMatched = literals.matches(object: object)
    #expect(literalsMatched)

    var arena = try ObjectPredicate<4, 4, 4, 3>(path: "a", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) { try arena.appendCondition(path: "b", expression: .equals(.number("2"))) }
    let arenaMatched = arena.matches(object: object)
    #expect(arenaMatched)
}
