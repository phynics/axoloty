// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyWire
import Testing

/// Deterministic, bounded property tests for the portable wire boundary.
///
/// These tests deliberately exercise only Foundation-free APIs. The fixed
/// seed makes a failing input reproducible while the bounded iteration count
/// keeps ordinary verification bounded.
@Suite("Deterministic wire fuzz")
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

    @Test("generated integer fields survive wire encode and decode")
    func integerFieldsRoundTrip() throws {
        var generator = SeededGenerator(seed: seed ^ 0x1111_2222)
        let values = [Int.min, Int.max, 0] + (0..<iterations).map { _ in
            generator.int(in: -2_000_000_000...2_000_000_000)
        }

        for (iteration, value) in values.enumerated() {
            var output = [UInt8](repeating: 0, count: 96)
            let count = try output.withUnsafeMutableBufferPointer { buffer throws -> Int in
                var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
                try writer.beginObject()
                try writer.writeIntField("value", value)
                try writer.endObject()
                return writer.position
            }

            let encoded = Array(output[..<count])
            withPointer(to: encoded) { pointer, count in
                let reader = WireReader(bytes: pointer, length: count)
                #expect(reader.readInt("value") == value, "iteration=\(iteration) value=\(value)")
            }
        }
    }

    @Test("generated UUIDs survive topic construction and strict validation")
    func topicConstructionRoundTrips() throws {
        var generator = SeededGenerator(seed: seed ^ 0x3333_4444)
        let eventTypes: [WireEventType] = [
            .advertise, .deadvertise, .channel, .associate, .ioValue,
            .discover, .resolve, .query, .retrieve, .update, .complete,
            .call, .returnEvent,
        ]

        for iteration in 0..<iterations {
            let source = makeUUID(generator.bytes(count: 16))
            let correlation = makeUUID(generator.bytes(count: 16))
            let eventType = eventTypes[iteration % eventTypes.count]
            var topic = [UInt8](repeating: 0, count: WireBufferConfig.maxTopicLength)
            let topicLength = try topic.withUnsafeMutableBufferPointer { buffer throws -> Int in
                var builder = TopicBuilder(buffer: buffer.baseAddress!, capacity: buffer.count)
                try builder.writePrefix()
                try builder.writeNamespace("fuzz")
                try builder.writeEventType(eventType)
                try builder.writeSourceId(source)
                if !eventType.isOneWay {
                    try builder.writeCorrelationId(correlation)
                }
                return builder.position
            }

            let topicBytes = Array(topic[..<topicLength])
            withPointer(to: topicBytes) { pointer, count in
                let view = TopicView(topicBytes: pointer, length: count)
                #expect(view.eventType != nil, "iteration=\(iteration)")
                #expect(view.level(3)?.equals(eventType.wireCode) == true, "iteration=\(iteration)")
                #expect(view.levelCount == (eventType.isOneWay ? 5 : 6), "iteration=\(iteration)")
                #expect(view.level(4).flatMap(UUID16.init(parsing:)) == source, "iteration=\(iteration) source")
                if eventType.isOneWay {
                    #expect(view.level(5) == nil, "iteration=\(iteration) unexpected correlation")
                } else {
                    #expect(
                        view.level(5).flatMap(UUID16.init(parsing:)) == correlation,
                        "iteration=\(iteration) correlation"
                    )
                }
                do {
                    try view.validate()
                } catch {
                    Issue.record("seed=\(seed) iteration=\(iteration) topic validation failed: \(error)")
                }
            }
        }
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % width)
    }

    mutating func bytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }
}

private func makeUUID(_ bytes: [UInt8]) -> UUID16 {
    precondition(bytes.count == 16)
    return UUID16(bytes: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private func withPointer<R>(to bytes: [UInt8], _ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
    if bytes.isEmpty {
        var sentinel: UInt8 = 0
        return withUnsafePointer(to: &sentinel) { body($0, 0) }
    }
    return bytes.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress!, buffer.count)
    }
}
