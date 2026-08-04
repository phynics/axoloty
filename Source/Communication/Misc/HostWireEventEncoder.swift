// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

extension HostWireAdapter {
    /// Encodes a host communication event with an AxolotyWire-owned envelope.
    static func encodeEvent(_ event: Any) throws -> [UInt8] {
        let wire: OwnedWireEvent
        switch event {
        case let value as AdvertiseEvent: wire = .advertise(.init(object: try encode(value.data.object), privateData: try encodeJSONObject(value.data.privateData)))
        case let value as DeadvertiseEvent: wire = .deadvertise(.init(objectIds: try encode(value.data.objectIds)))
        case let value as ChannelEvent: wire = .channel(.init(object: try value.data.object.map(encode), objects: try value.data.objects.map(encode), privateData: try encodeJSONObject(value.data.privateData)))
        case let value as AssociateEvent:
            guard let source = UUID16(parsing: value.data.ioSourceId.string), let actor = UUID16(parsing: value.data.ioActorId.string) else { throw AxolotyError.invalidArgument(argument: "event", reason: "Associate contains an invalid UUID") }
            wire = .associate(.init(ioSourceId: source, ioActorId: actor, associatingRoute: value.data.associatingRoute.map { Array($0.utf8) }, isExternalRoute: value.data.isExternalRoute, updateRate: value.data.updateRate))
        case let value as DiscoverEvent: wire = .discover(.init(externalId: value.data.externalId.map { Array($0.utf8) }, objectId: value.data.objectId.map { Array($0.string.utf8) }, objectTypes: try value.data.objectTypes.map(encode), coreTypes: try value.data.coreTypes.map(encode)))
        case let value as ResolveEvent:
            guard let object = value.data.object else { throw AxolotyError.invalidArgument(argument: "event", reason: "Resolve requires an object") }
            wire = .resolve(.init(object: try encode(object), relatedObjects: try value.data.relatedObjects.map(encode), privateData: try encodeJSONObject(value.data.privateData)))
        case let value as QueryEvent:
            let joins: [UInt8]?
            if let many = value.data.objectJoinConditions { joins = try encode(many) }
            else { joins = try value.data.objectJoinCondition.map(encode) }
            wire = .query(.init(objectTypes: try value.data.objectTypes.map(encode), coreTypes: try value.data.coreTypes.map(encode), objectFilter: try encode(value.data.objectFilter ?? ObjectFilter()), objectJoinConditions: joins))
        case let value as RetrieveEvent: wire = .retrieve(.init(objects: try encode(value.data.objects), privateData: try encodeJSONObject(value.data.privateData)))
        case let value as UpdateEvent: wire = .update(.init(object: try encode(value.data.object)))
        case let value as CompleteEvent: wire = .complete(.init(object: try value.data.object.map(encode), privateData: try encodeJSONObject(value.data.privateData)))
        case let value as CallEvent: wire = .call(.init(parameters: value.data.parameters.map { Array($0.utf8) }, filter: try value.data.filter.map(encode)))
        case let value as ReturnEvent: wire = .returnEvent(.init(result: value.data.result.map { Array($0.utf8) }, executionInfo: value.data.executionInfo.map { Array($0.utf8) }, error: try value.data.error.map(encode)))
        default: throw AxolotyError.invalidArgument(argument: "event", reason: "Unsupported communication event type")
        }
        return try encode(wire)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        do { return Array(try JSONEncoder().encode(value)) } catch { throw AxolotyError.caught(error) }
    }

    private static func encodeJSONObject(_ value: [String: Any]?) throws -> [UInt8]? {
        guard let value else { return nil }
        do { return Array(try JSONSerialization.data(withJSONObject: value)) } catch { throw AxolotyError.caught(error) }
    }

    private static func encode(_ event: OwnedWireEvent) throws -> [UInt8] {
        var capacity = WireBufferConfig.maxPayloadSize
        while capacity <= 16 * 1_024 * 1_024 {
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
