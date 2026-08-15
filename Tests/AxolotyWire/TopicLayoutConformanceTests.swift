// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// Protocol-conformance tests for the exact Coaty topic layout and event codes
/// (issue #488).
///
/// The live receive path calls ``TopicView/validate()`` before routing, so a
/// topic that fails these checks is dropped with a structured diagnostic
/// rather than decoded into a spurious event family. These tests lock in the
/// exact segment-count and event-code contract:
///
/// `coaty/3/<namespace>/<eventType>[:<filter>]/<sourceId>[/<correlationId>]`
@Suite
struct TopicLayoutConformanceTests {

    private let sourceId =
        "11111111-1111-4111-8111-111111111111"
    private let correlationId =
        "22222222-2222-4222-8222-222222222222"

    private func view(_ topic: String) -> TopicView {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count)
        }
    }

    private func validated(_ topic: String) throws(WireDecodeError) {
        try view(topic).validate()
    }

    // MARK: - Exact event codes

    @Test
    func exactThreeByteEventCodeIsRecognized() throws {
        #expect(view("coaty/3/ns/ADV/\(sourceId)").eventType == .advertise)
        #expect(view("coaty/3/ns/DSC/\(sourceId)/\(correlationId)").eventType == .discover)
        #expect(view("coaty/3/ns/IOV/\(sourceId)").eventType == .ioValue)
    }

    @Test
    func eventCodeWithFilterIsRecognized() throws {
        #expect(view("coaty/3/ns/ADV:sensors/\(sourceId)").eventType == .advertise)
        #expect(view("coaty/3/ns/CHN:channel-a/\(sourceId)").eventType == .channel)
    }

    @Test
    func overLongEventCodeSharingPrefixIsRejected() {
        // Near-match codes that merely share the three-byte prefix must not
        // decode. Previously `eventType` coarse-prefix-matched `ADVZ` -> advertise.
        #expect(view("coaty/3/ns/ADVZ/\(sourceId)").eventType == nil)
        #expect(view("coaty/3/ns/ADVX:foo/\(sourceId)").eventType == nil)
        #expect(view("coaty/3/ns/DSCX/\(sourceId)/\(correlationId)").eventType == nil)
    }

    @Test
    func eventCodeWithOversizedPreFilterPrefixIsRejected() {
        // `ADVF:foo` has four bytes before ':' — not an exact three-byte code.
        #expect(view("coaty/3/ns/ADVF:foo/\(sourceId)").eventType == nil)
    }

    @Test
    func shortEventCodeIsRejected() {
        #expect(view("coaty/3/ns/AD/\(sourceId)").eventType == nil)
        #expect(view("coaty/3/ns//\(sourceId)").eventType == nil)
    }

    // MARK: - Exact layouts (validate)

    @Test
    func validOneWayLayoutPasses() throws {
        try validated("coaty/3/ns/ADV/\(sourceId)")
        try validated("coaty/3/ns/DAD/\(sourceId)")
        try validated("coaty/3/ns/CHN:channel-a/\(sourceId)")
        try validated("coaty/3/ns/ASC:io-ctx/\(sourceId)")
        try validated("coaty/3/ns/IOV/\(sourceId)")
    }

    @Test
    func validTwoWayLayoutPasses() throws {
        try validated("coaty/3/ns/DSC/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/RSV/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/QRY/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/RTV/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/UPD:type/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/CPL/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/CLL:op/\(sourceId)/\(correlationId)")
        try validated("coaty/3/ns/RTN/\(sourceId)/\(correlationId)")
    }

    @Test
    func extraPathSegmentIsRejected() {
        // A valid prefix plus an extra trailing path segment must not route.
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADV/\(sourceId)/extra")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/DSC/\(sourceId)/\(correlationId)/extra")
        }
    }

    @Test
    func oneWayEventWithCorrelationIsRejected() {
        // One-way events carry exactly 5 levels and never a correlation ID.
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADV/\(sourceId)/\(correlationId)")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/IOV/\(sourceId)/\(correlationId)")
        }
    }

    @Test
    func twoWayEventsWithoutCorrelationAreRejected() {
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/DSC/\(sourceId)")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/QRY/\(sourceId)")
        }
    }

    @Test
    func wrongProtocolOrVersionIsRejected() {
        #expect(throws: (any Error).self) {
            try validated("other/3/ns/DAD/\(sourceId)")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/4/ns/DAD/\(sourceId)")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/ns/DAD/\(sourceId)")
        }
    }

    @Test
    func invalidSourceIdIsRejected() {
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADV/not-a-uuid")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADV/")
        }
    }

    @Test
    func malformedEventCodeFailsStructuredValidation() {
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADVZ/\(sourceId)")
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADVF:foo/\(sourceId)")
        }
    }

    @Test
    func rawNonCoatyTopicIsOutOfScopeForValidation() {
        // Raw (non-Coaty) topics are intentionally handled as raw messages
        // and are rejected by ``TopicView/validate()`` because they do not
        // carry the `coaty/3` prefix at all.
        #expect(throws: (any Error).self) {
            try validated("external/io-external-1")
        }
    }

    // MARK: - Structured diagnostics

    @Test
    func validationThrowsStructuredMalformedTopicError() {
        do {
            try validated("coaty/3/ns/ADV/\(sourceId)/extra")
            Issue.record("expected validation failure")
        } catch {
            // `validated` uses typed throws, so `catch` binds the error
            // directly as a ``WireDecodeError``.
            guard case .malformedTopic = error.reason else {
                Issue.record("expected .malformedTopic, got \(error.reason)")
                return
            }
        }
    }
}
