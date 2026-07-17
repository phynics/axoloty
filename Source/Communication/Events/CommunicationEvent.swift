//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CommunicationEvent.swift
//  Axoloty
//
//

import ErrorKit
import Foundation

/// CommunicationEvent is a generic supertype for all defined Coaty event types.
public class CommunicationEvent<T: CommunicationEventData>: Codable {
    
    // MARK: - Attributes.
    
    /// Event data of this event.
    private(set) public var data: T

    /// Object ID of the event source.
    internal(set) public var sourceId: CoatyUUID?

    /// Event type of this event.
    internal var type: CommunicationEventType?

    /// Event type filter of this event.
    internal var typeFilter: String?
    
    // MARK: - Initializer.
    
    init(eventType: CommunicationEventType, eventData: T) {
        self.type = eventType
        self.data = eventData
    }
    
    // MARK: - Codable methods.
    
    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.data = try container.decode(T.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

// MARK: - Extension enable easy access to JSON representation of event data.

extension CommunicationEvent {
    /// JSON representation of this event.
    ///
    /// - Note: Falls back to `"{}"` and logs the failure if the event data
    ///   cannot be encoded (e.g. a ``Double`` field holding `NaN`/`infinity`).
    ///   Kept non-throwing because it is read from dozens of publish call
    ///   sites that do not otherwise throw; see ``PayloadCoder/encode(_:)``.
    public var json: String {
        get {
            return PayloadCoder.encodeForJSON(self)
        }
    }
}

/// CommunicationEventData provides the generic type required by the CommunicationEvent.
/// Note that this cannot be a type alias since we need it to be an actual class.
public class CommunicationEventData: Codable {}
