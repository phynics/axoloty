// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

/// Shared host-side payload ceiling for Codable ingress and wire encoding.
/// Embedded ingress remains bounded by ``WireBufferConfig.maxPayloadSize``.
enum HostWirePayloadLimits {
    static let maxPayloadSize = 16 * 1_024 * 1_024
}

private enum HostOwnedJSONShape {
    case any
    case object
    case array
    case objectOrArray
}

extension HostWireAdapter {
    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Decodes a host-runtime event whose payload is larger than the embedded
    /// wire reader's fixed ingress limit.
    ///
    /// The embedded path remains bounded by ``WireReader`` and
    /// ``BorrowedMessage/validated(topicBytes:topicLength:payloadBytes:payloadLength:)``.
    /// Host MQTT receives are already owned by the client, so they use the
    /// Codable model and are converted to the same owned wire representation
    /// before crossing the asynchronous delivery boundary.
    static func decodeEvent(from bytes: [UInt8], eventType: WireEventType) throws -> OwnedWireEvent {
        guard bytes.count <= HostWirePayloadLimits.maxPayloadSize else {
            throw AxolotyError.decodingFailure(
                type: eventType.rawValue,
                reason: "payload exceeds the 16 MiB host limit",
                payload: nil
            )
        }
        guard let json = String(bytes: bytes, encoding: .utf8) else {
            throw AxolotyError.decodingFailure(
                type: eventType.rawValue,
                reason: "Payload is not valid UTF-8",
                payload: nil
            )
        }
        switch eventType {
        case .advertise: return try ownedEvent(decode(AdvertiseEvent.self, from: json))
        case .deadvertise: return try ownedEvent(decode(DeadvertiseEvent.self, from: json))
        case .channel: return try ownedEvent(decode(ChannelEvent.self, from: json))
        case .associate: return try ownedEvent(decode(AssociateEvent.self, from: json))
        case .ioValue: return try ownedEvent(decode(IoValueEvent.self, from: json))
        case .discover: return try ownedEvent(decode(DiscoverEvent.self, from: json))
        case .resolve: return try ownedEvent(decode(ResolveEvent.self, from: json))
        case .query: return try ownedEvent(decode(QueryEvent.self, from: json))
        case .retrieve: return try ownedEvent(decode(RetrieveEvent.self, from: json))
        case .update: return try ownedEvent(decode(UpdateEvent.self, from: json))
        case .complete: return try ownedEvent(decode(CompleteEvent.self, from: json))
        case .call: return try ownedEvent(decode(CallEvent.self, from: json))
        case .returnEvent: return try ownedEvent(decode(ReturnEvent.self, from: json))
        }
    }

    /// Encodes a host communication event with an AxolotyWire-owned envelope.
    static func encodeEvent(_ event: Any) throws -> [UInt8] {
        try encode(ownedEvent(event))
    }

    private static func ownedEvent(_ event: Any) throws -> OwnedWireEvent {
        do {
            let wire: OwnedWireEvent
            switch event {
        case let value as AdvertiseEvent:
            let object = try hostRaw(try encode(value.data.object), field: "object", shape: .object)
            let privateData = try hostOptionalRaw(try encodeJSONObject(value.data.privateData), field: "privateData", shape: .object)
            wire = .advertise(try OwnedAdvertiseWireData(object: object, privateData: privateData))
        case let value as DeadvertiseEvent:
            let objectIds = try hostRaw(try encode(value.data.objectIds), field: "objectIds", shape: .array)
            wire = .deadvertise(try OwnedDeadvertiseWireData(objectIds: objectIds))
        case let value as ChannelEvent:
            let object = try hostOptionalRaw(try value.data.object.map(encode), field: "object", shape: .object)
            let objects = try hostOptionalRaw(try value.data.objects.map(encode), field: "objects", shape: .array)
            let privateData = try hostOptionalRaw(try encodeJSONObject(value.data.privateData), field: "privateData", shape: .object)
            wire = .channel(try OwnedChannelWireData(object: object, objects: objects, privateData: privateData))
        case let value as AssociateEvent:
            guard let source = UUID16(parsing: value.data.ioSourceId.string), let actor = UUID16(parsing: value.data.ioActorId.string) else { throw AxolotyError.invalidArgument(argument: "event", reason: "Associate contains an invalid UUID") }
            let route = try value.data.associatingRoute.map(encodedStringContent)
            wire = .associate(try OwnedAssociateWireData(ioSourceId: source, ioActorId: actor, associatingRoute: route, isExternalRoute: value.data.isExternalRoute, updateRate: value.data.updateRate))
        case let value as IoValueEvent:
            let payload: [UInt8]
            if let rawPayload = value.data.rawPayload {
                payload = try encode(rawPayload)
            } else if let jsonPayload = value.data.jsonPayload {
                payload = Array(jsonPayload.utf8)
            } else {
                payload = Array("null".utf8)
            }
            wire = .ioValue(try OwnedIoValueWireData(payload: hostRaw(payload, field: "payload", shape: .any)))
        case let value as DiscoverEvent:
            let externalId = try value.data.externalId.map(encodedStringContent)
            let objectId = try value.data.objectId.map { try encodedStringContent($0.string) }
            let objectTypes = try hostOptionalRaw(try value.data.objectTypes.map(encode), field: "objectTypes", shape: .array)
            let coreTypes = try hostOptionalRaw(try value.data.coreTypes.map(encode), field: "coreTypes", shape: .array)
            wire = .discover(try OwnedDiscoverWireData(externalId: externalId, objectId: objectId, objectTypes: objectTypes, coreTypes: coreTypes))
        case let value as ResolveEvent:
            guard let object = value.data.object else { throw AxolotyError.invalidArgument(argument: "event", reason: "Resolve requires an object") }
            let rawObject = try hostRaw(try encode(object), field: "object", shape: .object)
            let relatedObjects = try hostOptionalRaw(try value.data.relatedObjects.map(encode), field: "relatedObjects", shape: .array)
            let privateData = try hostOptionalRaw(try encodeJSONObject(value.data.privateData), field: "privateData", shape: .object)
            wire = .resolve(try OwnedResolveWireData(object: rawObject, relatedObjects: relatedObjects, privateData: privateData))
        case let value as QueryEvent:
            let joins: [UInt8]?
            if let many = value.data.objectJoinConditions { joins = try encode(many) }
            else { joins = try value.data.objectJoinCondition.map(encode) }
            let objectTypes = try hostOptionalRaw(try value.data.objectTypes.map(encode), field: "objectTypes", shape: .array)
            let coreTypes = try hostOptionalRaw(try value.data.coreTypes.map(encode), field: "coreTypes", shape: .array)
            let objectFilter = try hostRaw(try encode(value.data.objectFilter ?? ObjectFilter()), field: "objectFilter", shape: .object)
            let objectJoinConditions = try hostOptionalRaw(joins, field: "objectJoinConditions", shape: .objectOrArray)
            wire = .query(try OwnedQueryWireData(objectTypes: objectTypes, coreTypes: coreTypes, objectFilter: objectFilter, objectJoinConditions: objectJoinConditions))
        case let value as RetrieveEvent:
            let objects = try hostRaw(try encode(value.data.objects), field: "objects", shape: .array)
            let privateData = try hostOptionalRaw(try encodeJSONObject(value.data.privateData), field: "privateData", shape: .object)
            wire = .retrieve(try OwnedRetrieveWireData(objects: objects, privateData: privateData))
        case let value as UpdateEvent:
            wire = .update(try OwnedUpdateWireData(object: hostRaw(try encode(value.data.object), field: "object", shape: .object)))
        case let value as CompleteEvent:
            let object = try hostOptionalRaw(try value.data.object.map(encode), field: "object", shape: .object)
            let privateData = try hostOptionalRaw(try encodeJSONObject(value.data.privateData), field: "privateData", shape: .object)
            wire = .complete(try OwnedCompleteWireData(object: object, privateData: privateData))
        case let value as CallEvent:
            let parameters = try hostOptionalRaw(value.data.parameters.map { Array($0.utf8) }, field: "parameters", shape: .objectOrArray)
            let filter = try hostOptionalRaw(try value.data.filter.map(encode), field: "filter", shape: .object)
            wire = .call(try OwnedCallWireData(parameters: parameters, filter: filter))
        case let value as ReturnEvent:
            let result = try hostOptionalRaw(value.data.result.map { Array($0.utf8) }, field: "result", shape: .any)
            let executionInfo = try hostOptionalRaw(value.data.executionInfo.map { Array($0.utf8) }, field: "executionInfo", shape: .any)
            let error = try hostOptionalRaw(try value.data.error.map(encode), field: "error", shape: .object)
            wire = .returnEvent(try OwnedReturnWireData(result: result, executionInfo: executionInfo, error: error))
            default:
                throw AxolotyError.invalidArgument(argument: "event", reason: "Unsupported communication event type")
            }
            return wire
        } catch {
            guard let axolotyError = error as? AxolotyError else {
                throw AxolotyError.caught(error)
            }
            throw axolotyError
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func hostRaw(
        _ bytes: [UInt8],
        field: StaticString,
        shape: HostOwnedJSONShape
    ) throws(WireDecodeError) -> [UInt8] {
        do {
            if bytes.count <= WireBufferConfig.maxPayloadSize {
                let wireValid = bytes.withUnsafeBufferPointer { buffer -> Bool in
                    guard let base = buffer.baseAddress else { return false }
                    return WireReader.isValidJSONValue(ByteSlice(bytes: base, length: buffer.count))
                }
                guard wireValid else {
                    throw WireDecodeError(.unexpectedToken(expected: "valid JSON value", actual: nil), field: field)
                }
            }
            let value = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
            guard hostShapeMatches(value, shape) else {
                throw WireDecodeError(.typeMismatch(expected: expectedShape(shape)), field: field)
            }
            return bytes
        } catch {
            guard let failure = error as? WireDecodeError else {
                throw WireDecodeError(.unexpectedToken(expected: "valid JSON value", actual: nil), field: field)
            }
            throw WireDecodeError(failure.reason, byteOffset: failure.byteOffset, field: field)
        }
    }

    private static func hostOptionalRaw(
        _ bytes: [UInt8]?,
        field: StaticString,
        shape: HostOwnedJSONShape
    ) throws(WireDecodeError) -> [UInt8]? {
        guard let bytes else { return nil }
        return try hostRaw(bytes, field: field, shape: shape)
    }

    private static func hostShapeMatches(_ value: Any, _ shape: HostOwnedJSONShape) -> Bool {
        switch shape {
        case .any: return true
        case .object: return value is [String: Any] || value is NSDictionary
        case .array: return value is [Any] || value is NSArray
        case .objectOrArray: return value is [String: Any] || value is NSDictionary || value is [Any] || value is NSArray
        }
    }

    private static func expectedShape(_ shape: HostOwnedJSONShape) -> StaticString {
        switch shape {
        case .any: "valid JSON value"
        case .object: "object"
        case .array: "array"
        case .objectOrArray: "object or array"
        }
    }

    private static func encodedStringContent(_ value: String) throws -> [UInt8] {
        do {
            let encoded = Array(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
            guard encoded.count >= 2 else {
                throw AxolotyError.decodingFailure(type: "OwnedWireData", reason: "encoded string content is empty")
            }
            return Array(encoded.dropFirst().dropLast())
        } catch let error as AxolotyError {
            throw error
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        do { return Array(try JSONEncoder().encode(value)) } catch { throw AxolotyError.caught(error) }
    }

    private static func decode<T: Codable>(_ type: T.Type, from json: String) throws -> T {
        try PayloadCoder.decode(json)
    }

    private static func encodeJSONObject(_ value: [String: Any]?) throws -> [UInt8]? {
        guard let value else { return nil }
        do { return Array(try JSONSerialization.data(withJSONObject: value)) } catch { throw AxolotyError.caught(error) }
    }

    private static func encode(_ event: OwnedWireEvent) throws -> [UInt8] {
        var capacity = WireBufferConfig.maxPayloadSize
        while capacity <= HostWirePayloadLimits.maxPayloadSize {
            var output = [UInt8](repeating: 0, count: capacity)
            do {
                let count = try output.withUnsafeMutableBufferPointer { buffer -> Int in
                    guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
                    var writer = WireWriter(buffer: base, capacity: buffer.count)
                    try event.encode(to: &writer)
                    return writer.position
                }
                output.removeSubrange(count...)
                return output
            } catch WireEncodeError.bufferOverflow { capacity *= 2 } catch { throw AxolotyError.caught(error) }
        }
        throw AxolotyError.invalidArgument(argument: "event", reason: "encoded payload exceeds the 16 MiB host limit")
    }
}
