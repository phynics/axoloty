//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  DiscoverEvent.swift
//  Axoloty
//
//

import Foundation

/// DiscoverEvent provides a generic implementation for discovering CoatyObjects.
/// Note that this class should preferably be initialized by its withObject() method.
public class DiscoverEvent: CommunicationEvent<DiscoverEventData> {

    // MARK: - Static Factory Methods.

    /// Create a DiscoverEvent instance for discovering objects with the given
    /// external Id.
    ///
    /// - Parameters:
    ///     - externalId: the external ID to discover
    public static func with(externalId: String) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(externalId: externalId)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// external Id and core types.
    ///
    /// - Parameters:
    ///     - externalId: the external ID to discover
    ///     - coreTypes: an array of core types to discover
    public static func with(externalId: String, coreTypes: [CoreType]) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(externalId: externalId, coreTypes: coreTypes)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// external Id and object types.
    ///
    /// - Parameters:
    ///   - externalId: the external ID to discover.
    ///   - objectTypes: an array of object types to discover.
    public static func with(externalId: String, objectTypes: [String]) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(externalId: externalId, objectTypes: objectTypes)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// object Id.
    ///
    /// - Parameters:
    ///   - objectId: the object ID to discover
    public static func with(objectId: CoatyUUID) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(objectId: objectId)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// external Id and object Id.
    ///
    /// - Parameters:
    ///   - externalId: the external ID to discover
    ///   - objectId: the object ID to discover
    public static func with(externalId: String, objectId: CoatyUUID) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(externalId: externalId, objectId: objectId)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// core types.
    ///
    /// - Parameters:
    ///   - coreTypes: coreTypes the core types to discover
    public static func with(coreTypes: [CoreType]) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(coreTypes: coreTypes)
        return .init(eventType: .discover, eventData: discoverEventData)
    }
    
    /// Create a DiscoverEvent instance for discovering objects with the given
    /// object types.
    ///
    /// - Parameters:
    ///   - objectTypes: the object types to discover
    public static func with(objectTypes: [String]) -> DiscoverEvent {
        let discoverEventData = DiscoverEventData(objectTypes: objectTypes)
        return .init(eventType: .discover, eventData: discoverEventData)
    }

    // MARK: - Initializers.

    fileprivate override init(eventType: WireEventType, eventData: DiscoverEventData) {
        super.init(eventType: eventType, eventData: eventData)
    }

    // MARK: - Codable methods.

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

}

/// DiscoverEventData provides the entire message payload data of a
/// `DiscoverEvent`.
public class DiscoverEventData: CommunicationEventData {
    
    // MARK: - Attributes.
    
    /// The external ID of the object(s) to be discovered or nil.
    ///
    /// - NOTE: externalId can be used exclusively or in combination with objectId property.
    /// Only if used exclusively it can be combined with objectTypes or coreTypes properties.
    public var externalId: String?

    /// The object UUID of the object to be discovered or nil.
    ///
    /// - NOTE: objectId can be used exclusively or in combination with externalId property.
    ///  Must not be used in combination with objectTypes or coreTypes properties.
    public var objectId: CoatyUUID?

    /// Restrict objects by object types (logical OR).
    ///
    /// - NOTE: objectTypes must not be used with objectId property.
    /// Should not be used in combination with coreTypes.
    public var objectTypes: [String]?

    /// Restrict objects by core types (logical OR).
    ///
    /// - NOTE: coreTypes must not be used with objectId property.
    /// Should not be used in combination with objectTypes.
    public var coreTypes: [CoreType]?

    // MARK: - Initializers.
    
    private init(externalId: String?, objectId: CoatyUUID?, objectTypes: [String]?, coreTypes: [CoreType]?) {
        self.externalId = externalId
        self.objectId = objectId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        super.init()
    }
    
    // MARK: - Convenience initializers that cover all permitted parameter combinations.
    
    required init(objectId: CoatyUUID) {
        self.objectId = objectId
        super.init()
    }
    
    required init(externalId: String, objectTypes: [String], coreTypes: [CoreType]) {
        self.externalId = externalId
        self.objectTypes = objectTypes
        self.coreTypes = coreTypes
        super.init()
    }
    
    required init(externalId: String, objectTypes: [String]) {
        self.externalId = externalId
        self.objectTypes = objectTypes
        super.init()
    }
    
    required init(externalId: String, coreTypes: [CoreType]) {
        self.externalId = externalId
        self.coreTypes = coreTypes
        super.init()
    }
    
    required init(externalId: String) {
        self.externalId = externalId
        super.init()
    }
    
    required init(objectId: CoatyUUID, externalId: String) {
        self.objectId = objectId
        self.externalId = externalId
        super.init()
    }
    
    required init(coreTypes: [CoreType], objectTypes: [String]) {
        self.coreTypes = coreTypes
        self.objectTypes = objectTypes
        super.init()
    }
    
    required init(coreTypes: [CoreType]) {
        self.coreTypes = coreTypes
        super.init()
    }
    
    required init(objectTypes: [String]) {
        self.objectTypes = objectTypes
        super.init()
    }
    
    required init(externalId: String, objectId: CoatyUUID) {
        self.externalId = externalId
        self.objectId = objectId
        super.init()
    }

    // MARK: - Codable methods.
    
    enum DiscoverKeys: String, CodingKey {
        case externalId
        case objectId
        case objectTypes
        case coreTypes
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscoverKeys.self)
        
        // Decode attributes.
        externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
        objectId = try container.decodeIfPresent(CoatyUUID.self, forKey: .objectId)
        coreTypes = try container.decodeIfPresent([CoreType].self, forKey: .coreTypes)
        objectTypes = try container.decodeIfPresent([String].self, forKey: .objectTypes)
        try super.init(from: decoder)
    }
    
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: DiscoverKeys.self)
        
        // Encode attributes.
        try container.encodeIfPresent(externalId, forKey: .externalId)
        try container.encodeIfPresent(objectId, forKey: .objectId)
        try container.encodeIfPresent(coreTypes, forKey: .coreTypes)
        try container.encodeIfPresent(objectTypes, forKey: .objectTypes)
    }
    
}
