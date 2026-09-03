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

    /// Parses `topic` and returns its ``TopicView/eventType`` computed while
    /// the backing buffer is still pinned by the closure.
    ///
    /// `TopicView` borrows its backing bytes without copying, so it must
    /// never escape the `withUnsafeBufferPointer` scope that owns them (see
    /// ``validated(_:)`` below for the same pattern). Returning the `TopicView`
    /// itself, as an earlier version of this helper did, left it holding a
    /// dangling pointer into a deallocated `Array` the instant the function
    /// returned.
    private func eventType(_ topic: String) -> WireEventType? {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            TopicView(topicBytes: buf.baseAddress!, length: buf.count).eventType
        }
    }

    private func validated(_ topic: String) throws(WireDecodeError) {
        let bytes = Array(topic.utf8)
        try bytes.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) throws(WireDecodeError) in
            try TopicView(topicBytes: buffer.baseAddress!, length: buffer.count).validate()
        }
    }

    @Test
    func builderWritesDynamicNamespaceAndObjectTypeFilter() throws {
        let source = try #require(UUID16(parsing: sourceId))
        let namespace = Array("dynamic-ns".utf8)
        let filter = Array("coaty.Identity".utf8)
        var output = [UInt8](repeating: 0, count: 128)
        let topic = output.withUnsafeMutableBufferPointer { destination in
            namespace.withUnsafeBufferPointer { namespaceBytes in
                filter.withUnsafeBufferPointer { filterBytes in
                    var builder = TopicBuilder(buffer: destination.baseAddress!, capacity: destination.count)
                    try! builder.writePrefix()
                    try! builder.writeNamespace(ByteSlice(pointer: namespaceBytes.baseAddress!, length: namespaceBytes.count))
                    try! builder.writeEventType(
                        .advertise,
                        filter: ByteSlice(pointer: filterBytes.baseAddress!, length: filterBytes.count),
                        filterKind: .objectType
                    )
                    try! builder.writeSourceId(source)
                    return String(decoding: destination.prefix(builder.position), as: UTF8.self)
                }
            }
        }
        #expect(topic == "coaty/3/dynamic-ns/ADV::coaty.Identity/\(sourceId)")
    }

    // MARK: - Exact event codes

    @Test
    func exactThreeByteEventCodeIsRecognized() throws {
        #expect(eventType("coaty/3/ns/ADV/\(sourceId)") == .advertise)
        #expect(eventType("coaty/3/ns/DSC/\(sourceId)/\(correlationId)") == .discover)
        #expect(eventType("coaty/3/ns/IOV/\(sourceId)") == .ioValue)
    }

    @Test
    func eventCodeWithFilterIsRecognized() throws {
        #expect(eventType("coaty/3/ns/ADV:sensors/\(sourceId)") == .advertise)
        #expect(eventType("coaty/3/ns/CHN:channel-a/\(sourceId)") == .channel)
    }

    @Test
    func overLongEventCodeSharingPrefixIsRejected() {
        // Near-match codes that merely share the three-byte prefix must not
        // decode. Previously `eventType` coarse-prefix-matched `ADVZ` -> advertise.
        #expect(eventType("coaty/3/ns/ADVZ/\(sourceId)") == nil)
        #expect(eventType("coaty/3/ns/ADVX:foo/\(sourceId)") == nil)
        #expect(eventType("coaty/3/ns/DSCX/\(sourceId)/\(correlationId)") == nil)
    }

    @Test
    func eventCodeWithOversizedPreFilterPrefixIsRejected() {
        // `ADVF:foo` has four bytes before ':' — not an exact three-byte code.
        #expect(eventType("coaty/3/ns/ADVF:foo/\(sourceId)") == nil)
    }

    @Test
    func shortEventCodeIsRejected() {
        #expect(eventType("coaty/3/ns/AD/\(sourceId)") == nil)
        #expect(eventType("coaty/3/ns//\(sourceId)") == nil)
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
