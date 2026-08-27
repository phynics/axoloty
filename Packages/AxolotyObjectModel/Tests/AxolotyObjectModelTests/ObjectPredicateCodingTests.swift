// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

extension ObjectPredicateTests {
@Test func encodeDecodeRoundTripsDirectAndGroupedPredicates() throws {
    let direct = try ObjectPredicate<64, 4, 4, 256>(decoding: predicateSlice("{\"conditions\":[\"value\",[7,1.00]]}"))
    let grouped = try ObjectPredicate<128, 8, 8, 512>(decoding: predicateSlice("{\"conditions\":{\"or\":[[\"value\",[7,1.00]],[\"missing\",[9]]]}}"))
    var output = [UInt8](repeating: 0, count: 1024)
    let roundTrips = try output.withUnsafeMutableBufferPointer { buffer -> (Bool, Bool) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try direct.encode(to: &writer)
        let directBytes = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decodedDirect = try ObjectPredicate<64, 4, 4, 256>(decoding: directBytes)
        let directMatched = decodedDirect.matches(object: try predicateObject("{\"value\":1e0}"))
        writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try grouped.encode(to: &writer)
        let groupedBytes = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decodedGrouped = try ObjectPredicate<128, 8, 8, 512>(decoding: groupedBytes)
        return (directMatched, decodedGrouped.matches(object: try predicateObject("{\"value\":1e0}")))
    }
    #expect(roundTrips.0)
    #expect(roundTrips.1)
}

@Test func rootOrGroupRetainsCanonicalShape() throws {
    let predicate = try ObjectPredicate<128, 8, 8, 512>(decoding: predicateSlice("{\"conditions\":{\"or\":[[\"value\",[7,1]],[\"missing\",[9]]]}}"))
    var output = [UInt8](repeating: 0, count: 256)
    let encoded = try output.withUnsafeMutableBufferPointer { buffer -> ByteSlice in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try predicate.encode(to: &writer)
        return ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
    }
    #expect(encoded.equals("{\"conditions\":{\"or\":[[\"value\",[7,1]],[\"missing\",[9]]]}}"))
}

@Test func escapedPathSegmentsSurviveCanonicalRoundTrip() throws {
    let predicate = try ObjectPredicate<64, 8, 4, 256>(decoding: predicateSlice("{\"conditions\":[[\"a\\u002eb\"],[7,1]]}"))
    var output = [UInt8](repeating: 0, count: 256)
    let result = try output.withUnsafeMutableBufferPointer { buffer -> (Bool, Bool) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        try predicate.encode(to: &writer)
        let encoded = ByteSlice(bytes: buffer.baseAddress!, length: writer.position)
        let decoded = try ObjectPredicate<64, 8, 4, 256>(decoding: encoded)
        return (encoded.equals("{\"conditions\":[[\"a.b\"],[7,1]]}"), decoded.matches(object: try predicateObject("{\"a.b\":1}")))
    }
    #expect(result.0)
    #expect(result.1)
}
}
