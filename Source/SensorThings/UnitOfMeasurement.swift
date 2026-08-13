//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  UnitOfMeasurement.swift
//  Axoloty
//

import Foundation

/// An object containing three key-value pairs:
/// - The name property presents the full name of the unitOfMeasurement.
/// - The symbol property shows the textual form of the unit symbol.
/// - The definition contains the URI defining the unitOfMeasurement.
///
/// The values of these properties SHOULD follow the Unified Code for Unit of Measure (UCUM).
public struct UnitOfMeasurement: Codable {

    private enum CodingKeys: String, CodingKey {
        case name
        case symbol
        case definition
    }
    
    /// Full name of the UnitOfMeasurement such as Degree Celsius, or `nil` when
    /// the SensorThings datastream has no unit of measurement.
    public var name: String?

    /// Symbol of the unit such as degC, or `nil` when the SensorThings
    /// datastream has no unit of measurement.
    public var symbol: String?

    /// Link to unit definition such as:
    /// http://www.qudt.org/qudt/owl/1.0.0/unit/Instances.html#DegreeCelsius
    /// or `nil` when the SensorThings datastream has no unit of measurement.
    public var definition: String?

    /// Creates a unit of measurement from nullable SensorThings fields.
    ///
    /// The optional properties represent the protocol's nullable unit fields.
    ///
    /// - Parameters:
    ///   - name: The full name of the unit, or `nil` when it is not available.
    ///   - symbol: The textual unit symbol, or `nil` when it is not available.
    ///   - definition: The URI defining the unit, or `nil` when it is not available.
    public init(name: String?,
                symbol: String?,
                definition: String?) {
        self.name = name
        self.symbol = symbol
        self.definition = definition
    }

    /// Creates a populated unit of measurement.
    ///
    /// This overload preserves source compatibility for callers that provide
    /// the historically non-optional unit fields.
    ///
    /// - Parameters:
    ///   - name: The full name of the unit.
    ///   - symbol: The textual unit symbol.
    ///   - definition: The URI defining the unit.
    public init(name: String,
                symbol: String,
                definition: String) {
        self.init(name: Optional(name),
                  symbol: Optional(symbol),
                  definition: Optional(definition))
    }

    /// Creates a unit of measurement by decoding SensorThings fields.
    ///
    /// Missing and explicit `null` fields both decode as `nil`. Encoding the
    /// resulting value emits all three fields as explicit `null` values.
    ///
    /// - Parameter decoder: The decoder containing a SensorThings unit object.
    /// - Throws: A decoding error when a present field is not a string or `null`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        self.definition = try container.decodeIfPresent(String.self, forKey: .definition)
    }

    /// Encodes the unit of measurement using the SensorThings field names.
    ///
    /// All three fields are emitted. A `nil` property is encoded as explicit
    /// JSON `null`, including when the corresponding input field was missing.
    ///
    /// - Parameter encoder: The encoder receiving the SensorThings unit object.
    /// - Throws: An encoding error if a field cannot be written to the encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(definition, forKey: .definition)
    }
}
