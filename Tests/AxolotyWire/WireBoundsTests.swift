// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import AxolotyProtocol
import Foundation
import Testing

/// Malformed-input, truncation, nesting, size-limit, and capacity bounds tests
/// for the AxolotyWire codec (issue #301).
///
/// Every test verifies that malformed input is rejected with a structured
/// ``WireDecodeError`` rather than trapping, accessing out-of-bounds memory,
/// or performing unbounded work. At-limit inputs behave as documented;
/// limit+1 inputs are rejected before dispatch.

// MARK: - Minimal valid payloads per family

/// Minimal valid payloads for each wire family, used as the base for
/// truncation and corruption tests.
private let familyPayloads: [(family: String, payload: [UInt8])] = [
    ("ADV", Array(#"{"object":{"objectId":"test"}}"#.utf8)),
    ("DAD", Array(#"{"objectIds":["00000000-0000-4000-8000-000000000001"]}"#.utf8)),
    ("CHN", Array(#"{"object":{"id":"x"}}"#.utf8)),
    ("ASC", Array(#"{"ioSourceId":"00000000-0000-4000-8000-000000000001","ioActorId":"00000000-0000-4000-8000-000000000002"}"#.utf8)),
    ("IOV", Array(#"{"payload":1}"#.utf8)),
    ("DSC", Array(#"{}"#.utf8)),
    ("RSV", Array(#"{"object":{"id":"x"}}"#.utf8)),
    ("QRY", Array(#"{}"#.utf8)),
    ("RTV", Array(#"{"object":{"id":"x"}}"#.utf8)),
    ("UPD", Array(#"{"object":{"id":"x"}}"#.utf8)),
    ("CPL", Array(#"{}"#.utf8)),
    ("CLL", Array(#"{"parameters":{"value":1},"filter":null}"#.utf8)),
    ("RTN", Array(#"{}"#.utf8)),
]

// MARK: - Decode helper

private func attemptDecode(family: String, bytes: [UInt8]) -> Bool {
    if bytes.isEmpty {
        var dummy: UInt8 = 0
        return withUnsafePointer(to: &dummy) { ptr in
            let reader = WireReader(bytes: ptr, length: 0)
            switch family {
            case "ADV": return (try? AdvertiseWireData(from: reader)) != nil
            case "DAD": return (try? DeadvertiseWireData(from: reader)) != nil
            case "CHN": return (try? ChannelWireData(from: reader)) != nil
            case "ASC": return (try? AssociateWireData(from: reader)) != nil
            case "IOV": return (try? IoValueWireData(from: reader)) != nil
            case "DSC": return (try? DiscoverWireData(from: reader)) != nil
            case "RSV": return (try? ResolveWireData(from: reader)) != nil
            case "QRY": return (try? QueryWireData(from: reader)) != nil
            case "RTV": return (try? RetrieveWireData(from: reader)) != nil
            case "UPD": return (try? UpdateWireData(from: reader)) != nil
            case "CPL": return (try? CompleteWireData(from: reader)) != nil
            case "CLL": return (try? CallWireData(from: reader)) != nil
            case "RTN": return (try? ReturnWireData(from: reader)) != nil
            default: return false
            }
        }
    }
    return bytes.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return false }
        let reader = WireReader(bytes: base, length: ptr.count)
        switch family {
        case "ADV": return (try? AdvertiseWireData(from: reader)) != nil
        case "DAD": return (try? DeadvertiseWireData(from: reader)) != nil
        case "CHN": return (try? ChannelWireData(from: reader)) != nil
        case "ASC": return (try? AssociateWireData(from: reader)) != nil
        case "IOV": return (try? IoValueWireData(from: reader)) != nil
        case "DSC": return (try? DiscoverWireData(from: reader)) != nil
        case "RSV": return (try? ResolveWireData(from: reader)) != nil
        case "QRY": return (try? QueryWireData(from: reader)) != nil
        case "RTV": return (try? RetrieveWireData(from: reader)) != nil
        case "UPD": return (try? UpdateWireData(from: reader)) != nil
        case "CPL": return (try? CompleteWireData(from: reader)) != nil
        case "CLL": return (try? CallWireData(from: reader)) != nil
        case "RTN": return (try? ReturnWireData(from: reader)) != nil
        default: return false
        }
    }
}

private func validationError(_ reader: WireReader) -> WireDecodeError? {
    do {
        try reader.validate()
        return nil
    } catch {
        return error
    }
}

private func decodeReaderError(_ bytes: [UInt8]) -> WireDecodeError? {
    bytes.withUnsafeBufferPointer { buffer in
        validationError(WireReader(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

// MARK: - Single-pass implementation guard

@Suite("WireReader implementation bounds")
struct WireReaderImplementationTests {
    @Test("Strictness is folded into the tokenizer pass")
    func strictnessDoesNotUseASeparateScanner() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/AxolotyWire/Sources/AxolotyWire/WireReader.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbiddenPath in [
            "preflight(",
            "scanString(",
            "scanNumber(",
            "literal(",
            "hex4(",
            "capacity: buffer.count + 8",
            "capacity: buffer.count"
        ] {
            #expect(!source.contains(forbiddenPath), "Found unbounded tokenizer workspace: \(forbiddenPath)")
        }
        #expect(source.contains("capacity: WireBufferConfig.maxPayloadSize + 8"))
        #expect(source.components(separatedBy: "JSONTokenizer(bytes:").count - 1 == 1)
        #expect(source.components(separatedBy: ".scanValue()").count - 1 == 1)
    }

    @Test("One tokenizer pass preserves lexical error categories")
    func strictLexicalErrorsAreReportedByTheReader() {
        let vectors: [(input: String, expected: WireDecodeError.Reason)] = [
            (#"{"payload":01}"#, .invalidNumber),
            (#"{"payload":"\uD800"}"#, .invalidEscape),
            (#"{"payload":"\x"}"#, .invalidEscape),
            (#"{"payload":truth}"#, .invalidLiteral),
            (#"{"payload":[{]}}"#, .invalidNesting),
            (#"{"payload":1,"payload":2}"#, .duplicateField),
        ]

        for vector in vectors {
            let actual = decodeReaderError(Array(vector.input.utf8))
            let matches: Bool
            switch (actual?.reason, vector.expected) {
            case (.invalidNumber, .invalidNumber),
                 (.invalidEscape, .invalidEscape),
                 (.invalidLiteral, .invalidLiteral),
                 (.invalidNesting, .invalidNesting),
                 (.duplicateField, .duplicateField):
                matches = true
            default:
                matches = false
            }
            #expect(matches, "Unexpected error for \(vector.input): \(String(describing: actual))")
        }
    }

    @Test("A bounded nested value is indexed after the single tokenizer pass")
    func boundedNestedValueRemainsReadable() {
        let nested = String(repeating: "[", count: 7) + "0" + String(repeating: "]", count: 7)
        let bytes = Array(("{\"payload\":" + nested + "}").utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            let failure: WireDecodeError? = {
                do {
                    try reader.validate()
                    return nil
                } catch let error as WireDecodeError {
                    return error
                } catch {
                    Issue.record("Unexpected non-WireDecodeError: \(error)")
                    return nil
                }
            }()
            #expect(failure == nil, "Unexpected bounded-value failure: \(String(describing: failure?.reason))")
            #expect(reader.readRaw("payload") != nil)
        }
    }

    @Test("A truncated nested object cannot expose a field beyond the borrowed input")
    func truncatedNestedObjectDoesNotExposeOutOfBoundsSlice() {
        let bytes = Array(#"{"payload":{"x":1"#.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            let failure = validationError(reader)

            #expect(reader.readRaw("payload") == nil)
            guard let failure else {
                Issue.record("Expected truncated nested object to fail")
                return
            }
            guard case .unexpectedEndOfInput = failure.reason else {
                Issue.record("Expected unexpectedEndOfInput, got \(failure.reason)")
                return
            }
            #expect(failure.byteOffset == bytes.count)
        }
    }

    @Test("Unterminated strings preserve the end-of-input error", arguments: [
        #"{"payload":"abc"#,
        #"{"payload"#,
    ])
    func unterminatedStringReportsEndOfInput(_ input: String) {
        let bytes = Array(input.utf8)
        guard let failure = decodeReaderError(bytes) else {
            Issue.record("Expected unterminated string to fail")
            return
        }
        guard case .unexpectedEndOfInput = failure.reason else {
            Issue.record("Expected unexpectedEndOfInput, got \(failure.reason)")
            return
        }
        #expect(failure.byteOffset == bytes.count)
    }

    @Test("The direct reader rejects inputs above the bounded payload limit")
    func oversizedInputIsRejectedBeforeTokenization() {
        let bytes = [UInt8](repeating: 0x20, count: WireBufferConfig.maxPayloadSize + 1)
        guard let failure = decodeReaderError(bytes) else {
            Issue.record("Expected oversized input to fail")
            return
        }
        guard case .payloadExceedsLimit = failure.reason else {
            Issue.record("Expected payloadExceedsLimit, got \(failure.reason)")
            return
        }
        #expect(failure.byteOffset == bytes.count)
    }
}

// MARK: - Truncation tests

@Suite("Truncation bounds")
struct TruncationBoundsTests {
    @Test("Truncation at every byte offset does not trap", arguments: familyPayloads)
    func truncationNoTrap(_ entry: (family: String, payload: [UInt8])) {
        for offset in 0...entry.payload.count {
            let truncated = Array(entry.payload.prefix(offset))
            // Must not trap — either succeeds or throws WireDecodeError.
            _ = attemptDecode(family: entry.family, bytes: truncated)
        }
    }

    @Test("Full payload decodes successfully", arguments: familyPayloads)
    func fullPayloadDecodes(_ entry: (family: String, payload: [UInt8])) {
        #expect(attemptDecode(family: entry.family, bytes: entry.payload))
    }

    @Test("Empty input is rejected for families with required fields")
    func emptyInputRejectedForRequiredFields() {
        // Families with at least one required field reject empty input.
        let requiredFieldFamilies = ["ADV", "DAD", "ASC", "RSV", "RTV", "UPD", "CLL"]
        for family in requiredFieldFamilies {
            #expect(!attemptDecode(family: family, bytes: []),
                   "Family \(family) should reject empty input")
        }
    }

    @Test("Empty input is accepted for all-optional families")
    func emptyInputAcceptedForOptionalFields() {
        // Families where all fields are optional accept empty input `{}`
        // (but not truly empty bytes — those fail because `{` is expected).
        let optionalFamilies = ["DSC", "QRY", "CPL", "RTN"]
        for family in optionalFamilies {
            let empty: [UInt8] = Array("{}".utf8)
            #expect(attemptDecode(family: family, bytes: empty),
                   "Family \(family) should accept {}")
        }
    }
}

@Suite("Exhaustive wire event round trips")
struct ExhaustiveWireEventRoundTripTests {
    @Test("all 13 event families survive borrowed and owned encode", arguments: familyPayloads)
    func allFamilies(_ entry: (family: String, payload: [UInt8])) throws {
        let type: WireEventType = switch entry.family {
        case "ADV": .advertise; case "DAD": .deadvertise; case "CHN": .channel; case "ASC": .associate
        case "IOV": .ioValue; case "DSC": .discover; case "RSV": .resolve; case "QRY": .query
        case "RTV": .retrieve; case "UPD": .update; case "CPL": .complete; case "CLL": .call; default: .returnEvent
        }
        var source = entry.payload
        let (first, owned) = try source.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { throw WireDecodeError(.unexpectedEndOfInput) }
            let reader = WireReader(bytes: base, length: buffer.count)
            let borrowed = try BorrowedWireEvent(eventType: type, from: reader)
            let first = try encodeEvent(borrowed)
            return (first, try borrowed.owned())
        }
        source = Array(repeating: 0xA5, count: source.count)

        let second = try first.withUnsafeBufferPointer { output -> [UInt8] in
            let decoded = try BorrowedWireEvent(
                eventType: type,
                from: WireReader(bytes: output.baseAddress!, length: output.count)
            )
            #expect(eventFamily(decoded) == entry.family)
            return try encodeEvent(decoded)
        }
        #expect(second == first)

        let ownedBytes = try encodeOwned(owned)
        #expect(ownedBytes == first)
        let ownedSecond = try ownedBytes.withUnsafeBufferPointer { output -> [UInt8] in
            let decoded = try BorrowedWireEvent(
                eventType: type,
                from: WireReader(bytes: output.baseAddress!, length: output.count)
            )
            #expect(eventFamily(decoded) == entry.family)
            return try encodeEvent(decoded)
        }
        #expect(ownedSecond == ownedBytes)
    }
}

private func encodeEvent(_ event: BorrowedWireEvent) throws(WireEncodeError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = try bytes.withUnsafeMutableBufferPointer { (buffer) throws(WireEncodeError) in var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count); try event.encode(to: &writer); return writer.position }
    return Array(bytes[..<count])
}

private func encodeOwned(_ event: OwnedWireEvent) throws(WireEncodeError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = try bytes.withUnsafeMutableBufferPointer { (buffer) throws(WireEncodeError) in var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count); try event.encode(to: &writer); return writer.position }
    return Array(bytes[..<count])
}

private func eventFamily(_ event: BorrowedWireEvent) -> String {
    switch event { case .advertise: "ADV"; case .deadvertise: "DAD"; case .channel: "CHN"; case .associate: "ASC"; case .ioValue: "IOV"; case .discover: "DSC"; case .resolve: "RSV"; case .query: "QRY"; case .retrieve: "RTV"; case .update: "UPD"; case .complete: "CPL"; case .call: "CLL"; case .returnEvent: "RTN" }
}

// MARK: - Corruption tests

@Suite("Corruption bounds")
struct CorruptionBoundsTests {
    @Test("Single-byte corruption does not trap", arguments: familyPayloads)
    func corruptionNoTrap(_ entry: (family: String, payload: [UInt8])) {
        for i in 0..<entry.payload.count {
            var corrupted = entry.payload
            corrupted[i] ^= 0xFF
            _ = attemptDecode(family: entry.family, bytes: corrupted)
        }
    }

    @Test("Corrupted opening brace is rejected")
    func corruptedOpenBrace() {
        var bytes = Array(#"{"object":{"id":"x"}}"#.utf8)
        bytes[0] = 0x5B // '[' instead of '{'
        #expect(!attemptDecode(family: "ADV", bytes: bytes))
    }
}

// MARK: - Malformed input tests

@Suite("Malformed input bounds")
struct MalformedInputTests {
    private func decodeError(_ bytes: [UInt8]) -> WireDecodeError? {
        decodeReaderError(bytes)
    }

    @Test("Empty input")
    func emptyInput() {
        #expect(!attemptDecode(family: "ADV", bytes: []))
    }

    @Test("Invalid UTF-8 sequence")
    func invalidUTF8() {
        let bytes: [UInt8] = [0x7B, 0x22, 0xFF, 0xFE, 0x22, 0x3A, 0x31, 0x7D]
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }

    @Test("Invalid escape sequence")
    func invalidEscape() {
        let bytes = Array(#"{"operationType":"\x"}"#.utf8)
        _ = attemptDecode(family: "CLL", bytes: bytes) // must not trap
    }

    @Test("Invalid number")
    func invalidNumber() {
        let bytes = Array(#"{"timeout":--}"#.utf8)
        _ = attemptDecode(family: "CLL", bytes: bytes) // must not trap
    }

    @Test("Invalid literal")
    func invalidLiteral() {
        let bytes = Array(#"{"payload":tru}"#.utf8)
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }

    @Test("Strict lexical vectors are rejected")
    func strictLexicalVectors() {
        let textVectors = [
            #"{"payload":01}"#,
            #"{"payload":"\uD800"}"#,
            #"{"payload":"\uDC00"}"#,
            #"{"payload":"\x"}"#,
            #"{"payload":truth}"#,
            #"{"payload":[{]}}"#,
            #"{"payload":1} trailing"#,
            #"{"payload":1,"payload":2}"#,
        ]
        for vector in textVectors {
            #expect(decodeError(Array(vector.utf8)) != nil, "Accepted invalid JSON: \(vector)")
        }

        let invalidUTF8Sequences: [[UInt8]] = [
            [0xC0, 0x80],
            [0xE0, 0x80, 0x80],
            [0xED, 0xA0, 0x80],
            [0xF0, 0x80, 0x80, 0x80],
            [0xF4, 0x90, 0x80, 0x80],
            [0xF5, 0x80, 0x80, 0x80],
        ]
        for sequence in invalidUTF8Sequences {
            let bytes = Array(#"{"payload":""#.utf8) + sequence + Array(#""}"#.utf8)
            let error = decodeError(bytes)
            #expect(error != nil)
            if let error {
                guard case .invalidUTF8 = error.reason else {
                    Issue.record("Expected invalidUTF8, got \(error.reason)")
                    continue
                }
            }
        }
    }

    @Test("Nesting and field index bounds are enforced")
    func structuralBounds() {
        let tooDeep = #"{"payload":[[[[[[[[[]]]]]]]]]}"#
        let fields = (0...24).map { #""k\#($0)":\#($0)"# }.joined(separator: ",")
        let tooManyFields = "{\(fields)}"

        let depthError = decodeError(Array(tooDeep.utf8))
        #expect(depthError != nil)
        if let depthError {
            guard case .invalidNesting = depthError.reason else {
                Issue.record("Expected invalidNesting, got \(depthError.reason)")
                return
            }
        }

        let fieldError = decodeError(Array(tooManyFields.utf8))
        #expect(fieldError != nil)
        if let fieldError {
            guard case .fieldIndexOverflow = fieldError.reason else {
                Issue.record("Expected fieldIndexOverflow, got \(fieldError.reason)")
                return
            }
        }
    }

    @Test("Duplicate fields")
    func duplicateFields() {
        let bytes = Array(#"{"object":{"id":"a"},"object":{"id":"b"}}"#.utf8)
        _ = attemptDecode(family: "ADV", bytes: bytes) // must not trap
    }

    @Test("Reordered fields")
    func reorderedFields() {
        let bytes = Array(#"{"ioActorId":"00000000-0000-4000-8000-000000000002","ioSourceId":"00000000-0000-4000-8000-000000000001"}"#.utf8)
        #expect(attemptDecode(family: "ASC", bytes: bytes))
    }

    @Test("Unknown fields are ignored")
    func unknownFields() {
        let bytes = Array(#"{"object":{"id":"x"},"unknown":"y"}"#.utf8)
        #expect(attemptDecode(family: "ADV", bytes: bytes))
    }

    @Test("Missing required field")
    func missingRequiredField() {
        let bytes = Array(#"{"notObject":"x"}"#.utf8)
        #expect(!attemptDecode(family: "ADV", bytes: bytes))
    }

    @Test("Trailing data after object")
    func trailingData() {
        let bytes = Array(#"{"payload":1}extra"#.utf8)
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }

    @Test("Non-object input")
    func nonObjectInput() {
        let bytes = Array(#"[1,2,3]"#.utf8)
        #expect(!attemptDecode(family: "ADV", bytes: bytes))
    }

    @Test("Null input")
    func nullInput() {
        let bytes = Array(#"null"#.utf8)
        #expect(!attemptDecode(family: "ADV", bytes: bytes))
    }
}

// MARK: - Nesting depth tests

@Suite("Nesting depth bounds")
struct NestingDepthTests {
    private func nestedObject(depth: Int) -> [UInt8] {
        var s = #"{"payload":"#
        for _ in 0..<depth { s += #"{"a":"# }
        s += "1"
        for _ in 0..<depth { s += "}" }
        s += "}"
        return Array(s.utf8)
    }

    @Test("Nesting depth 1")
    func nestingDepth1() {
        let bytes = nestedObject(depth: 1)
        #expect(bytes.count <= WireBufferConfig.maxPayloadSize)
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }

    @Test("Nesting depth 8")
    func nestingDepth8() {
        let bytes = nestedObject(depth: 8)
        #expect(bytes.count <= WireBufferConfig.maxPayloadSize)
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }

    @Test("Nesting depth 32")
    func nestingDepth32() {
        let bytes = nestedObject(depth: 32)
        // Each level adds ~6 bytes; 32 levels = ~192 bytes, within 512.
        if bytes.count <= WireBufferConfig.maxPayloadSize {
            _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
        }
    }

    @Test("Nesting depth 128 exceeds payload cap")
    func nestingDepth128() {
        let bytes = nestedObject(depth: 128)
        // 128 levels × ~6 bytes = ~768 bytes, exceeds 512-byte cap.
        // The payload itself is valid JSON; the cap is enforced by
        // BorrowedMessage.validated, not WireReader. WireReader just reads.
        _ = attemptDecode(family: "IOV", bytes: bytes) // must not trap
    }
}

// MARK: - Size limit tests

@Suite("Size limit bounds")
struct SizeLimitTests {
    private func makeTopic(length: Int) -> [UInt8] {
        // Build a topic of exactly the desired length.
        // Format: coaty/3/bench/ADV:<padding>/00000000-0000-4000-8000-000000000001
        let prefix = "coaty/3/bench/ADV:"
        let suffix = "/00000000-0000-4000-8000-000000000001"
        let padLen = max(0, length - prefix.count - suffix.count)
        let topic = prefix + String(repeating: "A", count: padLen) + suffix
        // If exact length not achievable, trim or pad.
        var bytes = Array(topic.utf8)
        if bytes.count > length { bytes = Array(bytes.prefix(length)) }
        if bytes.count < length { bytes.append(contentsOf: Array(repeating: 0x41, count: length - bytes.count)) }
        return bytes
    }

    private func makePayload(size: Int) -> [UInt8] {
        // Build a payload of the desired byte size.
        let prefix = #"{"payload":""#
        let suffix = #""}"#
        let padCount = max(0, size - prefix.count - suffix.count)
        let padding = String(repeating: "x", count: padCount)
        return Array((prefix + padding + suffix).utf8)
    }

    @Test("Topic at limit (128 bytes) is accepted by validated")
    func topicAtLimit() throws {
        let topic = makeTopic(length: WireBufferConfig.maxTopicLength)
        let payload: [UInt8] = Array(#"{"payload":1}"#.utf8)
        #expect(topic.count == WireBufferConfig.maxTopicLength)
        try topic.withUnsafeBufferPointer { tp in
            try payload.withUnsafeBufferPointer { pp in
                _ = try BorrowedMessage.validated(
                    topicBytes: tp.baseAddress!, topicLength: tp.count,
                    payloadBytes: pp.baseAddress!, payloadLength: pp.count
                )
            }
        }
    }

    @Test("Topic exceeding limit (129 bytes) is rejected")
    func topicExceedsLimit() {
        let topic = makeTopic(length: WireBufferConfig.maxTopicLength + 1)
        let payload: [UInt8] = Array(#"{"payload":1}"#.utf8)
        #expect(topic.count == WireBufferConfig.maxTopicLength + 1)
        do {
            try topic.withUnsafeBufferPointer { tp in
                try payload.withUnsafeBufferPointer { pp in
                    _ = try BorrowedMessage.validated(
                        topicBytes: tp.baseAddress!, topicLength: tp.count,
                        payloadBytes: pp.baseAddress!, payloadLength: pp.count
                    )
                }
            }
            Issue.record("should have thrown topicExceedsLimit")
        } catch let error as WireDecodeError {
            if case .topicExceedsLimit = error.reason {
                // Expected.
            } else {
                Issue.record("expected topicExceedsLimit, got \(error.reason)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Empty topic (0 bytes) is accepted")
    func topicEmpty() throws {
        let payload: [UInt8] = Array(#"{"payload":1}"#.utf8)
        var dummy: UInt8 = 0
        try withUnsafePointer(to: &dummy) { topicPtr in
            try payload.withUnsafeBufferPointer { pp in
                _ = try BorrowedMessage.validated(
                    topicBytes: topicPtr, topicLength: 0,
                    payloadBytes: pp.baseAddress!, payloadLength: pp.count
                )
            }
        }
    }

    @Test("Payload at limit (512 bytes) is accepted by validated")
    func payloadAtLimit() throws {
        let payload = makePayload(size: WireBufferConfig.maxPayloadSize)
        let topic = makeTopic(length: 48)
        #expect(payload.count == WireBufferConfig.maxPayloadSize)
        try topic.withUnsafeBufferPointer { tp in
            try payload.withUnsafeBufferPointer { pp in
                _ = try BorrowedMessage.validated(
                    topicBytes: tp.baseAddress!, topicLength: tp.count,
                    payloadBytes: pp.baseAddress!, payloadLength: pp.count
                )
            }
        }
    }

    @Test("Payload exceeding limit (513 bytes) is rejected")
    func payloadExceedsLimit() {
        let payload = makePayload(size: WireBufferConfig.maxPayloadSize + 1)
        let topic = makeTopic(length: 48)
        #expect(payload.count == WireBufferConfig.maxPayloadSize + 1)
        do {
            try topic.withUnsafeBufferPointer { tp in
                try payload.withUnsafeBufferPointer { pp in
                    _ = try BorrowedMessage.validated(
                        topicBytes: tp.baseAddress!, topicLength: tp.count,
                        payloadBytes: pp.baseAddress!, payloadLength: pp.count
                    )
                }
            }
            Issue.record("should have thrown payloadExceedsLimit")
        } catch let error as WireDecodeError {
            if case .payloadExceedsLimit = error.reason {
                // Expected.
            } else {
                Issue.record("expected payloadExceedsLimit, got \(error.reason)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Empty payload (0 bytes) is accepted by validated")
    func payloadEmpty() throws {
        let topic = makeTopic(length: 48)
        var dummy: UInt8 = 0
        try topic.withUnsafeBufferPointer { tp in
            try withUnsafePointer(to: &dummy) { payloadPtr in
                _ = try BorrowedMessage.validated(
                    topicBytes: tp.baseAddress!, topicLength: tp.count,
                    payloadBytes: payloadPtr, payloadLength: 0
                )
            }
        }
    }

    @Test("One-byte payload is accepted by validated")
    func payloadOneByte() throws {
        let topic = makeTopic(length: 48)
        let payload: [UInt8] = [0x31] // "1"
        try topic.withUnsafeBufferPointer { tp in
            try payload.withUnsafeBufferPointer { pp in
                _ = try BorrowedMessage.validated(
                    topicBytes: tp.baseAddress!, topicLength: tp.count,
                    payloadBytes: pp.baseAddress!, payloadLength: pp.count
                )
            }
        }
    }

    @Test("Payload at limit-1 (511 bytes) is accepted")
    func payloadAtLimitMinusOne() throws {
        let payload = makePayload(size: WireBufferConfig.maxPayloadSize - 1)
        let topic = makeTopic(length: 48)
        #expect(payload.count == WireBufferConfig.maxPayloadSize - 1)
        try topic.withUnsafeBufferPointer { tp in
            try payload.withUnsafeBufferPointer { pp in
                _ = try BorrowedMessage.validated(
                    topicBytes: tp.baseAddress!, topicLength: tp.count,
                    payloadBytes: pp.baseAddress!, payloadLength: pp.count
                )
            }
        }
    }
}

// MARK: - Router capacity tests

@Suite("Router capacity bounds")
struct RouterCapacityTests {
    @Test("Flat subscribers at capacity (8) succeed, 9th is rejected")
    func flatSubscribersAtCapacity() {
        let router = try! EmbeddedMessageRouter()
        for _ in 0..<ProtocolBufferConfig.maxSubscribers {
            let token = router.subscribe(.advertise) { _ in }
            #expect(token != nil)
        }
        // 9th subscription should return nil.
        let overflow = router.subscribe(.advertise) { _ in }
        #expect(overflow == nil)
    }

    @Test("Unsubscribe frees a slot for reuse")
    func unsubscribeReusesSlot() {
        let router = try! EmbeddedMessageRouter()
        var tokens: [StaticDispatchTable.Token] = []
        for _ in 0..<ProtocolBufferConfig.maxSubscribers {
            tokens.append(router.subscribe(.advertise) { _ in }!)
        }
        // Remove one.
        router.unsubscribe(.advertise, tokens[0])
        // New subscription should succeed.
        let newToken = router.subscribe(.advertise) { _ in }
        #expect(newToken != nil)
    }

    @Test("Family entries at capacity (16) succeed, 17th is rejected")
    func familyEntriesAtCapacity() {
        let router = try! EmbeddedMessageRouter()
        for i in 0..<ProtocolBufferConfig.maxFamilyEntries {
            let token = router.subscribeAdvertise(filter: "filter-\(i)") { _ in }
            #expect(token != nil)
        }
        // 17th entry should return nil.
        let overflow = router.subscribeAdvertise(filter: "overflow") { _ in }
        #expect(overflow == nil)
    }

    @Test("Family subscribers at capacity (4) succeed, 5th is rejected")
    func familySubscribersAtCapacity() {
        let router = try! EmbeddedMessageRouter()
        for _ in 0..<ProtocolBufferConfig.maxFamilySubscribers {
            let token = router.subscribeAdvertise(filter: "same-filter") { _ in }
            #expect(token != nil)
        }
        // 5th subscriber for same key should return nil.
        let overflow = router.subscribeAdvertise(filter: "same-filter") { _ in }
        #expect(overflow == nil)
    }

    @Test("Family unsubscribe frees a slot for reuse")
    func familyUnsubscribeReusesSlot() {
        let router = try! EmbeddedMessageRouter()
        var tokens: [StaticFamilyTable<String>.Token] = []
        for _ in 0..<ProtocolBufferConfig.maxFamilySubscribers {
            tokens.append(router.subscribeAdvertise(filter: "reuse") { _ in }!)
        }
        router.unsubscribeAdvertise(tokens[0])
        let newToken = router.subscribeAdvertise(filter: "reuse") { _ in }
        #expect(newToken != nil)
    }
}

// MARK: - Linear work check

@Suite("Linear work check")
struct LinearWorkTests {
    private func makePayload(size: Int) -> [UInt8] {
        let prefix = #"{"payload":""#
        let suffix = #""}"#
        let padCount = max(0, size - prefix.count - suffix.count)
        return Array((prefix + String(repeating: "x", count: padCount) + suffix).utf8)
    }

    @Test("Decode latency scales linearly with input size")
    func linearWorkScaling() {
        // Measure decode time for payloads of increasing size.
        let sizes = [64, 128, 256, 512]
        var times: [(size: Int, nsPerOp: Int)] = []

        for size in sizes {
            let payload = makePayload(size: size)
            let iterations = 10_000

            let elapsed = payload.withUnsafeBufferPointer { ptr -> Int64 in
                let clock = ContinuousClock()
                let e = clock.measure {
                    for _ in 0..<iterations {
                        let reader = WireReader(bytes: ptr.baseAddress!, length: ptr.count)
                        _ = try? IoValueWireData(from: reader)
                    }
                }
                return e.components.seconds * 1_000_000_000 + e.components.attoseconds / 1_000_000_000
            }

            let nsPerOp = Int(elapsed) / iterations
            times.append((size, nsPerOp))
        }

        // Check that the ratio of per-op time to input size is roughly constant
        // (linear scaling). Allow 3× tolerance to account for cache effects and
        // measurement noise in debug builds.
        for i in 1..<times.count {
            let ratio0 = Double(times[0].nsPerOp) / Double(times[0].size)
            let ratioI = Double(times[i].nsPerOp) / Double(times[i].size)
            if ratio0 > 0 && ratioI / ratio0 > 3.0 {
                Issue.record("superlinear growth: size \(times[0].size)→\(times[i].size), ratio \(ratio0)→\(ratioI)")
            }
        }
    }
}
