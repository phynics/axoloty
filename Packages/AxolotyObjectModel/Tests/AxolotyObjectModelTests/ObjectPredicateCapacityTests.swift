// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyWire
@testable import AxolotyObjectModel

extension ObjectPredicateTests {
@Test func failedAppendConditionIsAtomic() throws {
    var predicate = try ObjectPredicate<4, 2, 2, 16>(path: "value", expression: .equals(.number("1")))
    #expect(throws: ObjectError.self) { try predicate.appendCondition(path: "a", expression: .equals(.string("this value cannot fit"))) }
    let matched = predicate.matches(object: try predicateObject("{\"value\":1,\"a\":\"this value cannot fit\"}"))
    #expect(matched)
}

@Test func malformedWirePredicatesAreRejected() throws {
    let malformed: [StaticString] = [
        ("{\"conditions\":[\"v\",[99,1]]}"), ("{\"conditions\":[\"v\",[9,1]]}"),
        ("{\"conditions\":[\"v\",[4,1]]}"), ("{\"conditions\":[\"a..b\",[7,1]]}"),
        ("{\"conditions\":[1,[7,1]]}"), ("{\"conditions\":[\"v\",[13,1]]}"),
        ("{\"conditions\":[\"v\",[7,{\"unterminated\":1]]}"),
    ]
    for value in malformed {
        #expect(throws: ObjectError.self) { _ = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice(value)) }
    }
}

@Test func malformedConditionSetsMatchObjectFilterCodableRules() throws {
    let malformed: [StaticString] = ["{\"conditions\":{}}", "{\"conditions\":{\"xor\":[]}}", "{\"conditions\":{\"and\":[],\"or\":[]}}"]
    for value in malformed {
        #expect(throws: ObjectError.self) { _ = try ObjectPredicate<64, 8, 8, 256>(decoding: predicateSlice(value)) }
    }
}

@Test func predicateCapacityFailureRetainsStructuredReason() throws {
    do {
        _ = try ObjectPredicate<1, 1, 1, 1>(decoding: predicateSlice("{\"conditions\":[\"v\",[7,1]]}"))
        Issue.record("expected predicate capacity failure")
    } catch { #expect(error.reason == .capacityExceeded) }
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
    let predicate = try ObjectPredicate<64, 4, 4, 256>(path: "value", expression: .equals(.number("123456789")))
    var tiny = [UInt8](repeating: 0xA5, count: 4)
    let failure = tiny.withUnsafeMutableBufferPointer { buffer -> (Bool, Int) in
        var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
        do { try predicate.encode(to: &writer); return (false, writer.position) }
        catch { return (true, writer.position) }
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
}
