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
    
    /// Full name of the UnitofMeasurement such as Degree Celsius, or `nil` when
    /// the SensorThings datastream has no unit of measurement.
    public var name: String?

    /// Symbol of the unit such as degC, or `nil` when the SensorThings
    /// datastream has no unit of measurement.
    public var symbol: String?

    /// Link to unit definition such as:
    /// http://www.qudt.org/qudt/owl/1.0.0/unit/Instances.html#DegreeCelsius
    /// or `nil` when the SensorThings datastream has no unit of measurement.
    public var definition: String?

    public init(name: String?,
                symbol: String?,
                definition: String?) {
        self.name = name
        self.symbol = symbol
        self.definition = definition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        self.definition = try container.decodeIfPresent(String.self, forKey: .definition)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(definition, forKey: .definition)
    }
}
