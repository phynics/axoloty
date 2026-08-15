// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  CoatyTimeIntervalTests.swift
//  Axoloty

@testable import Axoloty
import Foundation
import Testing

/// Regression tests for `CoatyTimeInterval` unit handling and wire round
/// trips.
///
/// Issue #445 / P1-3: `_start`, `_end` and `_duration` must all be expressed
/// in the single documented unit (milliseconds since the epoch for
/// timestamps, milliseconds for duration), and each of the four valid
/// interval formats must survive a Codable wire round trip and produce a
/// consistent ISO 8601 string. On the wire the interval travels as the raw
/// `_start`/`_end`/`_duration` fields (all in ms), so the round trip must
/// preserve them exactly.
@Suite
struct CoatyTimeIntervalTests {

    @Test
    func startEndFormatRoundTrips() throws {
        let original = CoatyTimeInterval(start: 1_600_000_000_000, end: 1_600_000_500_000)
        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Both timestamps are ms-precision and carried verbatim on the wire.
        #expect(json["_start"] as? Int == 1_600_000_000_000)
        #expect(json["_end"] as? Int == 1_600_000_500_000)

        let decoded = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        #expect(decoded.start == original.start)
        #expect(decoded.end == original.end)
        #expect(decoded.duration == nil)

        // ISO round trip: ms -> Date (ms / 1000) reproduces the same wall time.
        #expect(decoded.toLocalIntervalIsoString() == "2020-09-13T12:26:40Z/2020-09-13T12:35:00Z")
    }

    @Test
    func startDurationFormatRoundTrips() throws {
        let original = CoatyTimeInterval(start: 1_600_000_000_000, duration: 4_200_012)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        #expect(decoded.start == original.start)
        #expect(decoded.duration == original.duration)
        #expect(decoded.end == nil)

        // Duration is ms: /1000 gives whole seconds, so 4_200_012 ms -> PT4200S.
        #expect(decoded.toLocalIntervalIsoString() == "2020-09-13T12:26:40Z/PT4200S")
    }

    @Test
    func durationEndFormatRoundTrips() throws {
        let original = CoatyTimeInterval(duration: 5_000, end: 1_600_000_005_000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        #expect(decoded.duration == original.duration)
        #expect(decoded.end == original.end)
        #expect(decoded.start == nil)

        #expect(decoded.toLocalIntervalIsoString() == "PT5S/2020-09-13T12:26:45Z")
    }

    @Test
    func durationOnlyFormatRoundTrips() throws {
        // Duration-only is a valid wire format, but yields no ISO interval
        // string because there is no reference timestamp endpoint.
        let original = CoatyTimeInterval(duration: 4_200_012)
        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["_duration"] as? Int == 4_200_012)
        #expect(json["_start"] == nil)
        #expect(json["_end"] == nil)

        let decoded = try JSONDecoder().decode(CoatyTimeInterval.self, from: data)
        #expect(decoded.duration == original.duration)
        #expect(decoded.start == nil)
        #expect(decoded.end == nil)

        #expect(decoded.toLocalIntervalIsoString() == "")
        #expect(throws: AxolotyError.self) {
            _ = try decoded.validatedLocalIntervalIsoString()
        }
    }

    /// Validate that timestamps are treated as ms exactly once (not scaled
    /// twice): a start of 0 and end of 1000 ms is a 1-second interval, and a
    /// duration of 1000 ms is exactly 1 SI second.
    @Test
    func millisecondUnitsAreConsistent() throws {
        let interval = CoatyTimeInterval(start: 0, end: 1_000)
        #expect(interval.toLocalIntervalIsoString() == "1970-01-01T00:00:00Z/1970-01-01T00:00:01Z")
        #expect(try CoatyTimeInterval.toDurationIsoString(duration: 1_000) == "PT1S")
    }
}