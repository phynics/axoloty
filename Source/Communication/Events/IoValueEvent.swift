//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  IoValueEvent.swift
//  Axoloty
//
//

import Foundation
import AxolotyWire

public class IoValueEvent: CommunicationEvent<IoValueEventData> {
    
    // MARK: - Internal attributes.
    
    /// The IoSource on which to publish the IO value.
    internal var ioSource: IoSource?
    
    /// Publication topic for this topic-based event.
    internal var topic: String?
    
    /// Binding-specific publication options.
    internal var options: [String: Any]?
    
    // MARK: - Static Factory Methods.
    
    /// Create an IoValueEvent instance for the given IO source and IO value.
    ///
    /// The IO value can be either JSON compatible or in binary format as a
    /// [Uint8] . The data format of the given IO value **must** conform to
    /// the `useRawIoValues` property of the given IO source.
    /// That means, if this property is set to true, the
    /// given value must be in binary format; if this property is set to false,
    /// the value must be a JSON encodable object. If this constraint is
    /// violated, an error is thrown.
    ///
    /// - Parameters:
    ///     - ioSource: the IoSource for publishing
    ///     - value: a  `[UInt8]` value
    ///     - options: binding-specific publication options
    /// - Throws: throws if the given value data format does not comply with the
    ///     `IoSource.useRawIoValues` option
    public static func with(ioSource: IoSource, value: [UInt8], options: [String: Any]) throws -> IoValueEvent {
        let ioValueEventData = IoValueEventData.createFrom(rawPayload: value)
        return try IoValueEvent(eventType: .ioValue, eventData: ioValueEventData, ioSource: ioSource)
    }
    
    /// Create an IoValueEvent instance for the given IO source and IO value.
    ///
    /// The IO value can be either JSON compatible or in binary format as a
    /// [Uint8] . The data format of the given IO value **must** conform to
    /// the `useRawIoValues` property of the given IO source.
    /// That means, if this property is set to true, the
    /// given value must be in binary format; if this property is set to false,
    /// the value must be a JSON encodable object. If this constraint is
    /// violated, an error is thrown.
    ///
    /// - Parameters:
    ///     - ioSource: the IoSource for publishing
    ///     - value: raw JSON text for the IO value
    ///     - options: binding-specific publication options
    /// - Throws: throws if the given value data format does not comply with the
    ///     `IoSource.useRawIoValues` option
    public static func with(ioSource: IoSource, value: String, options: [String: Any]) throws -> IoValueEvent {
        let ioValueEventData = IoValueEventData.createFrom(jsonPayload: value)
        return try IoValueEvent(eventType: .ioValue, eventData: ioValueEventData, ioSource: ioSource)
    }
    
    // MARK: - Initializers.
    
    fileprivate override init(eventType: WireEventType, eventData: IoValueEventData) {
        super.init(eventType: eventType, eventData: eventData)
    }
    
    fileprivate init(eventType: WireEventType, eventData: IoValueEventData, ioSource: IoSource) throws {
        if let useRawIoValues = ioSource.useRawIoValues,
            (eventData.rawPayload != nil && !useRawIoValues) || (eventData.rawPayload == nil && useRawIoValues) {
            throw AxolotyError.invalidArgument(
                argument: "ioSource.useRawIoValues",
                reason: "inconsistent options chosen for IoValueEvent (see IoSource.useRawIoValues for reference)"
            )
        }
        
        super.init(eventType: eventType, eventData: eventData)
        self.ioSource = ioSource
    }
    
    // MARK: - Codable methods.
    
    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }
}

/// Codable event data for an IO value.
///
/// A JSON array is inherently ambiguous because Coaty represents raw bytes as
/// an array of byte values while JSON-mode IO values may also be arrays. The
/// decoder preserves the established raw-byte interpretation only when every
/// element can be decoded exactly as `UInt8` (including an empty array). All
/// other JSON values are retained as raw JSON text in ``jsonPayload``.
public class IoValueEventData: CommunicationEventData {
    
    // MARK: - Public attributes.
    
    /// The payload represented as raw bytes.
    ///
    /// During decoding this is populated only for JSON arrays whose every
    /// element is an integer in the `UInt8` range.
    public var rawPayload: [UInt8]?
    
    /// The structured payload represented as raw JSON text.
    ///
    /// Scalars, objects, and arrays that are not valid byte arrays are retained
    /// here so re-encoding preserves the CoatyJS payload shape.
    public var jsonPayload: String?
    
    // MARK: - Initializers.
    
    private init(_ rawPayload: [UInt8]? = nil,
                 _ jsonPayload: String? = nil) {
        super.init()
        self.rawPayload = rawPayload
        self.jsonPayload = jsonPayload
    }
    
    // MARK: - Static Factory methods.
    
    internal static func createFrom(rawPayload: [UInt8]?) -> IoValueEventData {
        return .init(rawPayload, nil)
    }
    
    internal static func createFrom(jsonPayload: String) -> IoValueEventData {
        return .init(nil, jsonPayload)
    }
    
    // MARK: - Codable methods.
    
    enum CodingKeys: String, CodingKey {
        case payload
    }
    
    /// Decodes a raw-byte or structured JSON IO value payload.
    ///
    /// Byte arrays take precedence over structured arrays to preserve the
    /// existing Codable wire representation. Arrays containing any non-byte
    /// element are decoded as structured JSON instead.
    ///
    /// - Parameter decoder: The decoder containing the `payload` field.
    /// - Throws: A `DecodingError` when `payload` is missing or is not valid
    ///   JSON. Public decoding through ``PayloadCoder/decode(_:)`` translates
    ///   this into ``AxolotyError/decodingFailure(type:reason:payload:)``.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let bytes = try? container.decode([UInt8].self, forKey: .payload) {
            self.rawPayload = bytes
            self.jsonPayload = nil
        } else {
            self.rawPayload = nil
            self.jsonPayload = try RawJSONValue.decodeRawString(from: container, forKey: .payload)
        }
        try super.init(from: decoder)
    }

    /// Encodes either ``rawPayload`` or ``jsonPayload`` under `payload`.
    ///
    /// - Parameter encoder: The encoder receiving the event data.
    /// - Throws: An encoding error if ``jsonPayload`` is not valid JSON or the
    ///   encoder cannot represent the selected payload.
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.rawPayload, forKey: .payload)
        try RawJSONValue.encodeRawStringIfPresent(self.jsonPayload, to: &container, forKey: .payload)
    }
}
