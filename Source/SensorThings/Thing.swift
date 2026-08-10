//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  Thing.swift
//  Axoloty
//

import Foundation

/// With regard to the Internet of Things, a thing is an object
/// of the physical world (physical things) or the information
/// world (virtual things) that is capable of being identified
/// and integrated into communication networks.
open class Thing: CoatyObject {
    
    // MARK: - Class registration.
    open override class var objectType: String {
        return register(objectType: SensorThingsTypes.OBJECT_TYPE_THING,
                        with: self)
    }
    
    // MARK: - Attributes.
    /// This is a short description of the corresponding Thing.
    public var description: String
    
    /// Application-annotated properties represented as arbitrary JSON values.
    ///
    /// Use the cases of ``RawJSONValue`` to read or assign string, number,
    /// Boolean, array, object, and `null` values. This property is encoded on
    /// the SensorThings wire as the `properties` object.
    public var jsonProperties: [String: RawJSONValue]?

    /// A deprecated string-only view of ``jsonProperties``.
    ///
    /// This view remains available for source compatibility with clients that
    /// only use string-valued properties. It returns `nil` when any property
    /// has a non-string JSON value. Assigning a value replaces ``jsonProperties``
    /// with string JSON values. Use ``jsonProperties`` for arbitrary JSON.
    @available(*, deprecated, message: "Use jsonProperties for arbitrary JSON property values.")
    public var properties: [String: String]? {
        get {
            guard let jsonProperties else { return nil }
            var properties: [String: String] = [:]
            for (key, value) in jsonProperties {
                guard case .string(let string) = value else { return nil }
                properties[key] = string
            }
            return properties
        }
        set {
            jsonProperties = newValue?.mapValues { .string($0) }
        }
    }
    
    // MARK: - Initializers.
    /// Creates a SensorThings thing.
    ///
    /// - Parameters:
    ///   - description: A short description of the thing.
    ///   - properties: The deprecated string-only property view. Use
    ///     `jsonProperties` for arbitrary JSON values.
    ///   - name: The thing's name.
    ///   - objectId: The thing's unique identifier.
    ///   - externalId: An optional external identifier.
    ///   - parentObjectId: An optional parent thing identifier.
    ///   - locationId: An optional associated location identifier.
    ///   - objectType: The concrete SensorThings object type.
    ///   - jsonProperties: Application-annotated properties as arbitrary JSON
    ///     values. When supplied, this takes precedence over `properties`.
    public init(description: String,
         properties: [String: String]? = nil,
         name: String,
         objectId: CoatyUUID = .init(),
         externalId: String? = nil,
         parentObjectId: CoatyUUID? = nil,
         locationId: CoatyUUID? = nil,
         objectType: String = Thing.objectType,
         jsonProperties: [String: RawJSONValue]? = nil) {
        self.jsonProperties = jsonProperties ?? properties?.mapValues { .string($0) }
        self.description = description
        
        super.init(coreType: .CoatyObject,
                   objectType: objectType,
                   objectId: objectId,
                   name: name)
        super.locationId = locationId
        
        self.externalId = externalId
        self.parentObjectId = parentObjectId
    }
    
    // MARK: - Codable methods.
    enum CodingKeys: String, CodingKey {
        case description
        case properties
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try container.decode(String.self, forKey: .description)
        self.jsonProperties = try container.decodeIfPresent(
            [String: RawJSONValue].self,
            forKey: .properties
        )
        try super.init(from: decoder)
    }
    
    override public func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonProperties, forKey: .properties)
        try container.encode(description, forKey: .description)
    }
}
