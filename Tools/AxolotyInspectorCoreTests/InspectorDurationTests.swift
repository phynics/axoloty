// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation
import Testing

@Suite
struct InspectorDurationTests {
    @Test
    func parsesSeconds() {
        let d = InspectorDuration(rawValue: "10s")
        #expect(d?.value == .seconds(10))
    }

    @Test
    func parsesMinutes() {
        let d = InspectorDuration(rawValue: "2m")
        #expect(d?.value == .seconds(120))
    }

    @Test
    func parsesHours() {
        let d = InspectorDuration(rawValue: "1h")
        #expect(d?.value == .seconds(3_600))
    }

    @Test
    func parsesUnlimited() {
        let d = InspectorDuration(rawValue: "unlimited")
        #expect(d == .unlimited)
        #expect(d?.value == nil)
    }

    @Test
    func parsesUnlimitedCaseInsensitive() {
        #expect(InspectorDuration(rawValue: "UNLIMITED") == .unlimited)
    }

    @Test
    func trimsWhitespace() {
        #expect(InspectorDuration(rawValue: "  5s  ")?.value == .seconds(5))
    }

    @Test
    func rejectsZero() {
        #expect(InspectorDuration(rawValue: "0s") == nil)
    }

    @Test
    func rejectsNegative() {
        #expect(InspectorDuration(rawValue: "-5s") == nil)
    }

    @Test
    func rejectsMalformed() {
        #expect(InspectorDuration(rawValue: "abc") == nil)
        #expect(InspectorDuration(rawValue: "10") == nil)
        #expect(InspectorDuration(rawValue: "s") == nil)
        #expect(InspectorDuration(rawValue: "") == nil)
    }

    @Test
    func rejectsUnknownUnit() {
        #expect(InspectorDuration(rawValue: "10d") == nil)
        #expect(InspectorDuration(rawValue: "10x") == nil)
    }

    @Test
    func rejectsExceedsMax() {
        #expect(InspectorDuration(rawValue: "25h") == nil)
        #expect(InspectorDuration(rawValue: "99999s") == nil)
        #expect(InspectorDuration(rawValue: "9223372036854775807m") == nil)
    }

    @Test
    func acceptsMaxBoundary() {
        #expect(InspectorDuration(rawValue: "24h")?.value == .seconds(86_400))
    }
}
