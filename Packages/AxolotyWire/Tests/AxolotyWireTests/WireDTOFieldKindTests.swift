// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import AxolotyWire

/// Proves that the borrowed wire DTOs reject a present field of the wrong kind
/// instead of treating it as absent, that every accepted payload also passes
/// `ownedEvent()`, and that both wire profiles behave the same.
@Suite("Wire DTO field kinds")
struct WireDTOFieldKindTests {
    private static let source = "33333333-3333-4333-8333-333333333333"
    private static let actor = "44444444-4444-4444-8444-444444444444"
    private static let objectID = "55555555-5555-4555-8555-555555555555"

    // MARK: - Kind-checked payloads

    private struct RejectedCase {
        let event: WireEventType
        let field: String
        let fields: [(String, TestValue)]
    }

    @Test("a present wrong-kind field is rejected as a structured payload error in both profiles")
    func wrongKindFieldsAreRejected() throws {
        let cases: [RejectedCase] = [
            .init(event: .associate, field: "associatingRoute", fields: [
                ("ioSourceId", .uuid(Self.source)),
                ("ioActorId", .uuid(Self.actor)),
                ("associatingRoute", .integer(42)),
            ]),
            .init(event: .associate, field: "associatingRoute", fields: [
                ("ioSourceId", .uuid(Self.source)),
                ("ioActorId", .uuid(Self.actor)),
                ("associatingRoute", .null),
            ]),
            .init(event: .associate, field: "isExternalRoute", fields: [
                ("ioSourceId", .uuid(Self.source)),
                ("ioActorId", .uuid(Self.actor)),
                ("isExternalRoute", .text("yes")),
            ]),
            .init(event: .associate, field: "updateRate", fields: [
                ("ioSourceId", .uuid(Self.source)),
                ("ioActorId", .uuid(Self.actor)),
                ("updateRate", .text("fast")),
            ]),
            .init(event: .advertise, field: "object", fields: [
                ("object", .integer(7)),
            ]),
            .init(event: .advertise, field: "privateData", fields: [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("privateData", .array([.integer(1), .integer(2)])),
            ]),
            .init(event: .deadvertise, field: "objectIds", fields: [
                ("objectIds", .object([])),
            ]),
            .init(event: .channel, field: "objects", fields: [
                ("objects", .object([])),
            ]),
            .init(event: .channel, field: "privateData", fields: [
                ("privateData", .array([])),
            ]),
            .init(event: .discover, field: "objectTypes", fields: [
                ("objectTypes", .object([])),
            ]),
            .init(event: .discover, field: "externalId", fields: [
                ("externalId", .integer(1)),
            ]),
            .init(event: .query, field: "objectFilter", fields: [
                ("objectFilter", .array([])),
            ]),
            .init(event: .query, field: "objectJoinConditions", fields: [
                ("objectJoinConditions", .text("conditions")),
            ]),
            .init(event: .call, field: "parameters", fields: [
                ("parameters", .text("x")),
            ]),
            .init(event: .call, field: "filter", fields: [
                ("filter", .array([])),
            ]),
            .init(event: .update, field: "object", fields: [
                ("object", .text("object")),
            ]),
            .init(event: .resolve, field: "relatedObjects", fields: [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("relatedObjects", .object([])),
            ]),
            .init(event: .resolve, field: "privateData", fields: [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("privateData", .array([])),
            ]),
            .init(event: .retrieve, field: "objects", fields: [
                ("objects", .text("objects")),
            ]),
            .init(event: .complete, field: "privateData", fields: [
                ("privateData", .array([])),
            ]),
            .init(event: .returnEvent, field: "error", fields: [
                ("error", .array([])),
            ]),
        ]

        for profile in [WireProfile.coaty3JSON, .axoloty1CBOR] {
            for testCase in cases {
                let bytes = TestValue.encodeObject(testCase.fields, profile: profile)
                switch decode(bytes, profile: profile, event: testCase.event) {
                case .accepted:
                    Issue.record("\(testCase.event) accepted a wrong-kind \(testCase.field) in \(profile)")
                case .ownedFailed(let message):
                    Issue.record("\(testCase.event) accepted a wrong-kind \(testCase.field) in \(profile) but ownedEvent \(message)")
                case .rejected(let field):
                    #expect(field == testCase.field, "\(testCase.event) rejected the wrong field in \(profile)")
                }
            }
        }
    }

    @Test("accepted payloads decode and pass ownedEvent in both profiles")
    func acceptedPayloadsPassOwnedValidation() throws {
        let cases: [(WireEventType, [(String, TestValue)])] = [
            (.associate, [
                ("ioSourceId", .uuid(Self.source)),
                ("ioActorId", .uuid(Self.actor)),
                ("associatingRoute", .text("coaty/3/IOV/\(Self.source)")),
                ("isExternalRoute", .boolean(false)),
                ("updateRate", .integer(250)),
            ]),
            (.advertise, [
                ("object", .object([("coreType", .text("CoatyObject")), ("objectId", .uuid(Self.objectID))])),
                ("privateData", .object([("enabled", .boolean(true))])),
            ]),
            (.deadvertise, [
                ("objectIds", .array([.uuid(Self.objectID)])),
            ]),
            (.channel, [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("objects", .array([.object([("objectId", .uuid(Self.source))])])),
                ("privateData", .object([])),
            ]),
            (.discover, [
                ("externalId", .text("external-1")),
                ("objectId", .text(Self.objectID)),
                ("objectTypes", .array([.text("coaty.test.Thing")])),
                ("coreTypes", .array([])),
            ]),
            (.query, [
                ("objectTypes", .array([])),
                ("coreTypes", .array([])),
                ("objectFilter", .object([("name", .text("thing"))])),
                ("objectJoinConditions", .array([])),
            ]),
            (.call, [
                ("parameters", .array([.integer(1)])),
                ("filter", .object([])),
            ]),
            (.resolve, [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("relatedObjects", .array([])),
                ("privateData", .object([])),
            ]),
            (.retrieve, [
                ("objects", .array([.object([("objectId", .uuid(Self.objectID))])])),
                ("privateData", .object([])),
            ]),
            (.update, [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
            ]),
            (.complete, [
                ("object", .object([("objectId", .uuid(Self.objectID))])),
                ("privateData", .object([])),
            ]),
            (.returnEvent, [
                ("result", .integer(49)),
                ("error", .object([])),
            ]),
            (.ioValue, [
                ("payload", .integer(7)),
            ]),
        ]

        for profile in [WireProfile.coaty3JSON, .axoloty1CBOR] {
            for (event, fields) in cases {
                let bytes = TestValue.encodeObject(fields, profile: profile)
                switch decode(bytes, profile: profile, event: event) {
                case .accepted:
                    break
                case .rejected(let field):
                    Issue.record("\(event) rejected a valid payload at \(field ?? "?") in \(profile)")
                case .ownedFailed(let message):
                    Issue.record("\(event) accepted a payload ownedEvent rejected in \(profile): \(message)")
                }
            }
        }
    }

    @Test("a legacy single-object Retrieve payload still decodes")
    func legacyRetrieveObject() throws {
        for profile in [WireProfile.coaty3JSON, .axoloty1CBOR] {
            let bytes = TestValue.encodeObject(
                [("object", .object([("objectId", .uuid(Self.objectID))]))],
                profile: profile
            )
            switch decode(bytes, profile: profile, event: .retrieve) {
            case .accepted: break
            case .rejected(let field): Issue.record("legacy Retrieve rejected at \(field ?? "?")")
            case .ownedFailed(let message): Issue.record("legacy Retrieve failed ownedEvent: \(message)")
            }
        }
    }

    // MARK: - Tag-37 skip shape

    @Test("the CBOR skip path requires tag 37 to wrap a 16-byte byte string")
    func taggedUUIDShapeIsCheckedWhenSkipping() throws {
        let shortened = cborMapWithRawValue(key: "value", value: [0xD8, 0x25, 0x41, 0x00])
        #expect(isMalformedUUID(skipReason(shortened)))

        let integer = cborMapWithRawValue(key: "value", value: [0xD8, 0x25, 0x18, 0x2A])
        #expect(isMalformedUUID(skipReason(integer)))

        let valid = cborMapWithRawValue(
            key: "value",
            value: [0xD8, 0x25, 0x50] + Array(repeating: 0, count: 16)
        )
        #expect(skipReason(valid) == nil)
    }

    // MARK: - Helpers

    private enum Outcome {
        case accepted
        case rejected(field: String?)
        case ownedFailed(String)
    }

    private func decode(_ bytes: [UInt8], profile: WireProfile, event: WireEventType) -> Outcome {
        bytes.withUnsafeBufferPointer { buffer in
            let codec = WireCodec(profile: profile)
            let reader = codec.reader(
                bytes: buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!,
                length: buffer.count
            )
            do throws(WireDecodeError) {
                let borrowed = try BorrowedWireEvent(eventType: event, from: reader)
                do throws(WireDecodeError) {
                    _ = try borrowed.owned(profile: profile)
                    return .accepted
                } catch {
                    return .ownedFailed("\(error)")
                }
            } catch {
                return .rejected(field: error.field.map { "\($0)" })
            }
        }
    }

    private func isMalformedUUID(_ reason: WireDecodeError.Reason?) -> Bool {
        guard let reason else { return false }
        if case .malformedUUID = reason { return true }
        return false
    }

    private func skipReason(_ bytes: [UInt8]) -> WireDecodeError.Reason? {
        bytes.withUnsafeBufferPointer { buffer -> WireDecodeError.Reason? in
            var reader = CBORReader(
                bytes: buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!,
                length: buffer.count
            )
            do throws(WireDecodeError) {
                try reader.skipItem()
                return nil
            } catch {
                return error.reason
            }
        }
    }

    private func cborMapWithRawValue(key: String, value: [UInt8]) -> [UInt8] {
        let keyBytes = Array(key.utf8)
        return head(5, 1) + head(3, UInt64(keyBytes.count)) + keyBytes + value
    }
}

// MARK: - Profile-neutral test payload builder

/// A tiny value model used to build the same logical payload in either wire
/// profile. The real encoder is not used because these tests need to build
/// payloads the DTOs must reject.
private indirect enum TestValue {
    case text(String)
    case integer(Int)
    case boolean(Bool)
    case null
    case uuid(String)
    case array([TestValue])
    case object([(String, TestValue)])

    static func encodeObject(_ fields: [(String, TestValue)], profile: WireProfile) -> [UInt8] {
        switch profile {
        case .coaty3JSON:
            return Array(jsonObject(fields).utf8)
        case .axoloty1CBOR:
            return cborObject(fields)
        }
    }

    private static func jsonValue(_ value: TestValue) -> String {
        switch value {
        case .text(let text): return "\"\(text)\""
        case .integer(let number): return String(number)
        case .boolean(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .uuid(let uuid): return "\"\(uuid)\""
        case .array(let values): return "[" + values.map(jsonValue).joined(separator: ",") + "]"
        case .object(let fields): return jsonObject(fields)
        }
    }

    private static func jsonObject(_ fields: [(String, TestValue)]) -> String {
        "{" + fields.map { "\"\($0.0)\":" + jsonValue($0.1) }.joined(separator: ",") + "}"
    }

    private static func cborObject(_ fields: [(String, TestValue)]) -> [UInt8] {
        let sorted = fields.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        var bytes = head(5, UInt64(sorted.count))
        for (key, value) in sorted {
            let keyBytes = Array(key.utf8)
            bytes += head(3, UInt64(keyBytes.count)) + keyBytes
            bytes += cborValue(value)
        }
        return bytes
    }

    private static func cborValue(_ value: TestValue) -> [UInt8] {
        switch value {
        case .text(let text):
            let bytes = Array(text.utf8)
            return head(3, UInt64(bytes.count)) + bytes
        case .integer(let number):
            return head(0, UInt64(number))
        case .boolean(let flag):
            return [flag ? 0xF5 : 0xF4]
        case .null:
            return [0xF6]
        case .uuid(let text):
            let uuid = UUID16(parsing: text)!
            return [0xD8, 0x25, 0x50] + uuidRawBytes(uuid)
        case .array(let values):
            return head(4, UInt64(values.count)) + values.flatMap(cborValue)
        case .object(let fields):
            return cborObject(fields)
        }
    }

    private static func uuidRawBytes(_ uuid: UUID16) -> [UInt8] {
        withUnsafeBytes(of: uuid.bytes) { Array($0) }
    }
}

private func head(_ major: UInt8, _ argument: UInt64) -> [UInt8] {
    let base = major << 5
    if argument < 24 {
        return [base | UInt8(argument)]
    }
    if argument <= 0xFF {
        return [base | 24, UInt8(argument)]
    }
    if argument <= 0xFFFF {
        return [base | 25, UInt8(argument >> 8), UInt8(argument & 0xFF)]
    }
    return [base | 26, UInt8((argument >> 24) & 0xFF), UInt8((argument >> 16) & 0xFF),
            UInt8((argument >> 8) & 0xFF), UInt8(argument & 0xFF)]
}
