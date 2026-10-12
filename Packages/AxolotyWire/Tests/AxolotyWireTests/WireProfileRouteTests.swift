// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyWire
import Testing

/// Route-prefix tests for the `axoloty/1` CBOR profile (epic #977).
///
/// The route prefix is the authoritative payload-encoding signal. These tests
/// pin the profile enum, the builder prefix, the parsed profile, and the
/// profile-scoped validation that keeps `coaty/3` and `axoloty/1` distinct.

@Suite
struct WireProfileRouteTests {
    private let sourceId = "11111111-1111-4111-8111-111111111111"
    private let correlationId = "22222222-2222-4222-8222-222222222222"

    private func profile(of topic: String) -> WireProfile? {
        let bytes = Array(topic.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            TopicView(topicBytes: buffer.baseAddress!, length: buffer.count).profile
        }
    }

    private func validated(_ topic: String, profile: WireProfile) throws(WireDecodeError) {
        let bytes = Array(topic.utf8)
        try bytes.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) throws(WireDecodeError) in
            try TopicView(topicBytes: buffer.baseAddress!, length: buffer.count).validate(profile: profile)
        }
    }

    @Test
    func profileNamesAndVersions() {
        #expect(String(describing: WireProfile.coaty3JSON.protocolName) == "coaty")
        #expect(String(describing: WireProfile.coaty3JSON.protocolVersion) == "3")
        #expect(String(describing: WireProfile.axoloty1CBOR.protocolName) == "axoloty")
        #expect(String(describing: WireProfile.axoloty1CBOR.protocolVersion) == "1")
        #expect(String(describing: WireProfile.coaty3JSON.contentType) == "application/json")
        #expect(String(describing: WireProfile.axoloty1CBOR.contentType) == "application/cbor")
        #expect(WireProfile.allCases.count == 2)
    }

    @Test
    func parsedProfileRecognizesBothPrefixes() {
        #expect(profile(of: "coaty/3/ns/ADV/\(sourceId)") == .coaty3JSON)
        #expect(profile(of: "axoloty/1/ns/ADV/\(sourceId)") == .axoloty1CBOR)
        #expect(profile(of: "coaty/4/ns/ADV/\(sourceId)") == nil)
        #expect(profile(of: "axoloty/2/ns/ADV/\(sourceId)") == nil)
        #expect(profile(of: "other/1/ns/ADV/\(sourceId)") == nil)
    }

    @Test
    func builderWritesBothPrefixes() throws {
        #expect(try prefixBytes { try $0.writePrefix() } == Array("coaty/3/".utf8))
        #expect(try prefixBytes { try $0.writePrefix(.coaty3JSON) } == Array("coaty/3/".utf8))
        #expect(try prefixBytes { try $0.writePrefix(.axoloty1CBOR) } == Array("axoloty/1/".utf8))
    }

    @Test
    func builderWritesAxolotyRoute() throws {
        let source = try #require(UUID16(parsing: sourceId))
        let correlation = try #require(UUID16(parsing: correlationId))
        let namespace = Array("ax-ns".utf8)
        var output = [UInt8](repeating: 0, count: 128)
        let topic = output.withUnsafeMutableBufferPointer { destination in
            namespace.withUnsafeBufferPointer { namespaceBytes in
                var builder = TopicBuilder(buffer: destination.baseAddress!, capacity: destination.count)
                try! builder.writePrefix(.axoloty1CBOR)
                try! builder.writeNamespace(
                    ByteSlice(pointer: namespaceBytes.baseAddress!, length: namespaceBytes.count)
                )
                try! builder.writeEventType(.discover)
                try! builder.writeSourceId(source)
                try! builder.writeCorrelationId(correlation)
                return String(decoding: destination.prefix(builder.position), as: UTF8.self)
            }
        }
        #expect(topic == "axoloty/1/ax-ns/DSC/\(sourceId)/\(correlationId)")
        try validated(topic, profile: .axoloty1CBOR)
    }

    @Test
    func axolotyRoutePassesAxolotyValidation() throws {
        try validated("axoloty/1/ns/ADV/\(sourceId)", profile: .axoloty1CBOR)
        try validated("axoloty/1/ns/IOV/\(sourceId)", profile: .axoloty1CBOR)
        try validated("axoloty/1/ns/DSC/\(sourceId)/\(correlationId)", profile: .axoloty1CBOR)
        try validated("axoloty/1/ns/UPD:type/\(sourceId)/\(correlationId)", profile: .axoloty1CBOR)
    }

    @Test
    func profilesAreNotInterchangeable() {
        // The default validation stays sealed to coaty/3.
        #expect(throws: (any Error).self) {
            try validated("axoloty/1/ns/ADV/\(sourceId)", profile: .coaty3JSON)
        }
        #expect(throws: (any Error).self) {
            try validated("coaty/3/ns/ADV/\(sourceId)", profile: .axoloty1CBOR)
        }
        // The parameterless default is coaty/3.
        #expect(throws: (any Error).self) {
            try validated("axoloty/1/ns/ADV/\(sourceId)", profile: .coaty3JSON)
        }
    }

    @Test
    func axolotyRouteRejectsMalformedLayouts() {
        #expect(throws: (any Error).self) {
            try validated("axoloty/1/ns/ADV/\(sourceId)/extra", profile: .axoloty1CBOR)
        }
        #expect(throws: (any Error).self) {
            try validated("axoloty/1/ns/ADV/not-a-uuid", profile: .axoloty1CBOR)
        }
        #expect(throws: (any Error).self) {
            try validated("axoloty/1/ns/DSC/\(sourceId)", profile: .axoloty1CBOR)
        }
    }

    private func prefixBytes(_ body: (inout TopicBuilder) throws -> Void) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 32)
        return try output.withUnsafeMutableBufferPointer { buffer -> [UInt8] in
            var builder = TopicBuilder(buffer: buffer.baseAddress!, capacity: buffer.count)
            try body(&builder)
            return Array(buffer.prefix(builder.position))
        }
    }
}
