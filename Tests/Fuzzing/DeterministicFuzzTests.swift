// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import Axoloty

/// Deterministic, bounded property tests for protocol-facing primitives.
///
/// Override the PR-friendly iteration count with `AXOLOTY_FUZZ_ITERATIONS` and
/// reproduce a failure with `AXOLOTY_FUZZ_SEED` (decimal or `0x` hexadecimal).
@Suite
struct DeterministicFuzzTests {
    private var iterations: Int {
        let value = ProcessInfo.processInfo.environment["AXOLOTY_FUZZ_ITERATIONS"]
            .flatMap(Int.init) ?? 250
        return min(max(value, 1), 100_000)
    }

    private var seed: UInt64 {
        let value = ProcessInfo.processInfo.environment["AXOLOTY_FUZZ_SEED"] ?? "0x41584f4c4f5459"
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16) ?? 0x41584f4c4f5459
        }
        return UInt64(value) ?? 0x41584f4c4f5459
    }

    @Test

    func testAnyCodableJSONRoundTripsSemantically() throws {
        var generator = SeededGenerator(seed: seed)
        for iteration in 0..<iterations {
            let value = generator.jsonValue(depth: 0)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
            let encoded = try JSONEncoder().encode(decoded)
            let actual = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
            #expect(jsonEqual(value, actual), "seed=\(seed) iteration=\(iteration)")
        }
    }

    @Test

    func testUnknownObjectFieldsDecodeWithoutLossInCustomDictionary() throws {
        var generator = SeededGenerator(seed: seed ^ 0x5555_aaaa)
        for iteration in 0..<iterations {
            let uuid = generator.uuidString()
            let customString = generator.string(maxLength: 32)
            let customInteger = generator.int(in: -1_000_000...1_000_000)
            let payload: [String: Any] = ["object": [
                "objectId": uuid,
                "coreType": "CoatyObject",
                "objectType": "example.Unregistered\(iteration)",
                "name": generator.string(maxLength: 32),
                "customString": customString,
                "customInteger": customInteger,
                "customNested": ["enabled": iteration.isMultiple(of: 2)]
            ]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let json = try #require(String(data: data, encoding: .utf8))
            let event: AdvertiseEvent = try #require(PayloadCoder.decode(json), "seed=\(seed) iteration=\(iteration)")
            #expect((event.data.object.objectId.string) == (uuid))
            #expect((event.data.object.custom["customString"] as? String) == (customString))
            #expect((event.data.object.custom["customInteger"] as? Int) == (customInteger))
            #expect((event.data.object.custom["customNested"]) != nil)
        }
    }

    @Test

    func testMalformedAndTruncatedPayloadsAreRejectedWithoutCrashing() throws {
        var generator = SeededGenerator(seed: seed ^ 0xdead_beef)
        let valid = "{\"data\":{\"object\":{\"objectId\":\"00000000-0000-4000-8000-000000000001\",\"coreType\":\"CoatyObject\",\"objectType\":\"coaty.CoatyObject\",\"name\":\"fixture\"}}}"
        for length in 0..<valid.utf8.count {
            let truncated = String(valid.prefix(length))
            let event: AdvertiseEvent? = PayloadCoder.decode(truncated)
            #expect((event) == nil, "truncation length \(length) unexpectedly decoded")
        }
        for iteration in 0..<iterations {
            let bytes = (0..<generator.int(in: 0...128)).map { _ in generator.uint8() }
            let malformed = String(decoding: bytes, as: UTF8.self)
            let event: AdvertiseEvent? = PayloadCoder.decode(malformed)
            if let event = event {
                #expect(!(event.data.object.objectType.isEmpty), "seed=\(seed) iteration=\(iteration)")
            }
        }
    }

    @Test

    func testUUIDParsingAndCodableRoundTrip() throws {
        var generator = SeededGenerator(seed: seed ^ 0xc0a7_900d)
        for iteration in 0..<iterations {
            let text = generator.uuidString()
            let uuid = try #require(CoatyUUID(uuidString: text), "seed=\(seed) iteration=\(iteration)")
            #expect((uuid.string) == (text))
            let decoded = try JSONDecoder().decode(CoatyUUID.self, from: JSONEncoder().encode(uuid))
            #expect((decoded) == (uuid))
            #expect((decoded.string) == (text))
        }
        for invalid in ["", "not-a-uuid", "00000000-0000-0000-0000", "00000000/0000/0000/0000/000000000000"] {
            #expect((CoatyUUID(uuidString: invalid)) == nil)
        }
    }

    @Test

    func testTopicMatcherAgreesWithReferenceImplementation() {
        var generator = SeededGenerator(seed: seed ^ 0x70f1_cafe)
        for iteration in 0..<iterations {
            let topic = generator.topic(allowWildcards: false)
            let filter = generator.topic(allowWildcards: true)
            #expect((CommunicationTopic.matches(topic, filter)) == (referenceMatches(topic: topic, filter: filter)), "seed=\(seed) iteration=\(iteration) topic=\(topic) filter=\(filter)")
        }
    }

    @Test

    func testTopicValidationProperties() {
        var generator = SeededGenerator(seed: seed ^ 0x1234_5678)
        for iteration in 0..<iterations {
            let clean = generator.string(maxLength: 24, alphabet: Array("abcXYZ012._-"))
            if clean.isEmpty {
                #expect(!(CommunicationTopic.isValidPublicationTopic(clean)))
            } else {
                #expect(CommunicationTopic.isValidPublicationTopic(clean), "iteration=\(iteration)")
                #expect(CommunicationTopic.isValidSubscriptionTopic(clean))
            }
            for forbidden in ["#", "+", "\u{0000}"] {
                #expect(!(CommunicationTopic.isValidPublicationTopic(clean + forbidden)))
            }
            #expect(!(CommunicationTopic.isValidSubscriptionTopic(clean + "\u{0000}")))
        }
    }

    private func referenceMatches(topic: String, filter: String) -> Bool {
        guard !topic.isEmpty, !filter.isEmpty else { return false }
        let topics = topic.components(separatedBy: "/")
        let filters = filter.components(separatedBy: "/")
        var index = 0
        while index < filters.count {
            if filters[index] == "#" { return index == filters.count - 1 }
            guard index < topics.count else { return false }
            guard filters[index] == "+" || filters[index] == topics[index] else { return false }
            index += 1
        }
        return index == topics.count
    }

    private func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhs = lhs as? NSNull, let rhs = rhs as? NSNull { return lhs === rhs }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber { return lhs == rhs }
        if let lhs = lhs as? String, let rhs = rhs as? String { return lhs == rhs }
        if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(jsonEqual)
        }
        if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
            return lhs.keys == rhs.keys && lhs.allSatisfy { key, value in jsonEqual(value, rhs[key]!) }
        }
        return false
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func uint8() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    mutating func string(maxLength: Int, alphabet: [Character] = Array("abcXYZ012 ._-\u{00e4}\u{6c34}\u{1f680}")) -> String {
        String((0..<int(in: 0...maxLength)).map { _ in alphabet[int(in: 0...(alphabet.count - 1))] })
    }

    mutating func uuidString() -> String {
        var bytes = (0..<16).map { _ in uint8() }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    mutating func topic(allowWildcards: Bool) -> String {
        let count = int(in: 1...7)
        return (0..<count).map { index in
            if allowWildcards && index == count - 1 && int(in: 0...7) == 0 { return "#" }
            if allowWildcards && int(in: 0...5) == 0 { return "+" }
            return string(maxLength: 8, alphabet: Array("abc012"))
        }.joined(separator: "/")
    }

    mutating func jsonValue(depth: Int) -> Any {
        let scalarOnly = depth >= 3
        switch int(in: 0...(scalarOnly ? 4 : 6)) {
        case 0: return NSNull()
        case 1: return Bool.random(using: &self)
        case 2: return int(in: -9_000_000...9_000_000)
        case 3: return Double(int(in: -1_000_000...1_000_000)) / 100.0
        case 4: return string(maxLength: 40)
        case 5: return (0..<int(in: 0...6)).map { _ in jsonValue(depth: depth + 1) }
        default:
            var object: [String: Any] = [:]
            for index in 0..<int(in: 0...6) { object["key\(index)_\(string(maxLength: 4))"] = jsonValue(depth: depth + 1) }
            return object
        }
    }
}
