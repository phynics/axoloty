// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

private func sensorThingsSchema<Value: Sendable>(
    _ type: StaticString,
    _ fields: [(StaticString, ObjectFieldFlags)]
) -> PortableObjectSchema<Value> {
    var descriptors = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    for (index, field) in fields.enumerated() {
        descriptors[index] = ObjectFieldDescriptor(
            key: ObjectFieldKey(field.0)!,
            index: UInt8(index),
            flags: field.1
        )
    }
    return PortableObjectSchema(
        objectType: ObjectType(type)!,
        coreType: .coatyObject,
        fieldCount: UInt8(fields.count),
        fields: descriptors
    )
}

private let required: ObjectFieldFlags = .required
private let optional: ObjectFieldFlags = .required.union(.presence)

/// Marker for the four SensorThings object schemas carried by the product.
public protocol SensorThingsTopLevelSchema: ObjectSchema {}

/// The SensorThings unit of measurement. Missing and explicit null values are
/// distinct while decoding; an absent value is normalized to explicit null
/// when this value is encoded again.
public struct UnitOfMeasurement: ObjectSchema, Sendable, Equatable {
    /// Unit name.
    public var name: Presence<BoundedEncodedText<128>>
    /// Unit symbol.
    public var symbol: Presence<BoundedEncodedText<128>>
    /// Unit definition URI.
    public var definition: Presence<BoundedEncodedText<128>>

    private var rawSnapshot: SensorThingsJSONValue?

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<UnitOfMeasurement> = sensorThingsSchema(
        "coaty.sensorThings.UnitOfMeasurement",
        [("name", optional), ("symbol", optional), ("definition", optional)]
    )

    /// Creates a unit value from explicit presence states.
    public init(
        name: Presence<BoundedEncodedText<128>> = .missing,
        symbol: Presence<BoundedEncodedText<128>> = .missing,
        definition: Presence<BoundedEncodedText<128>> = .missing
    ) {
        self.name = name
        self.symbol = symbol
        self.definition = definition
        self.rawSnapshot = nil
    }

    /// Decodes a unit while preserving missing/null/value state.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        name = try fields.presence("name", as: BoundedEncodedText<128>.self)
        symbol = try fields.presence("symbol", as: BoundedEncodedText<128>.self)
        definition = try fields.presence("definition", as: BoundedEncodedText<128>.self)
        fields.withEncodedBytes { bytes in self.rawSnapshot = try? SensorThingsJSONValue(copying: bytes) }
    }

    /// Encodes all unit keys while preserving missing and explicit null states.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(name, forKey: "name")
        try encoder.encode(symbol, forKey: "symbol")
        try encoder.encode(definition, forKey: "definition")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.symbol == rhs.symbol && lhs.definition == rhs.definition
    }
}

/// A SensorThings observed property descriptor.
public struct ObservedProperty: ObjectSchema, Sendable, Equatable {
    /// Human-readable property name.
    public var name: BoundedEncodedText<128>
    /// Property definition URI.
    public var definition: BoundedEncodedText<128>
    /// Human-readable property description.
    public var description: BoundedEncodedText<128>

    private var rawSnapshot: SensorThingsJSONValue?

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<ObservedProperty> = sensorThingsSchema(
        "coaty.sensorThings.ObservedProperty",
        [("name", required), ("definition", required), ("description", required)]
    )

    /// Creates an observed property.
    public init(
        name: BoundedEncodedText<128>,
        definition: BoundedEncodedText<128>,
        description: BoundedEncodedText<128>
    ) {
        self.name = name
        self.definition = definition
        self.description = description
        self.rawSnapshot = nil
    }

    /// Decodes an observed property.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        name = try fields.decode("name", as: BoundedEncodedText<128>.self)
        definition = try fields.decode("definition", as: BoundedEncodedText<128>.self)
        description = try fields.decode("description", as: BoundedEncodedText<128>.self)
        fields.withEncodedBytes { bytes in self.rawSnapshot = try? SensorThingsJSONValue(copying: bytes) }
    }

    /// Encodes an observed property.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(name, forKey: "name")
        try encoder.encode(definition, forKey: "definition")
        try encoder.encode(description, forKey: "description")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.definition == rhs.definition && lhs.description == rhs.description
    }
}

/// The closed OGC observation types supported by the historical product.
public enum ObservationType: String, Sendable, Equatable, ObjectFieldDecodable, ObjectFieldEncodable {
    /// Category observation.
    case categoryObservation = "http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Category_Observation"
    /// Count observation.
    case countObservation = "http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_CountObservation"
    /// Measurement observation.
    case measurement = "http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Measurement"
    /// General observation.
    case observation = "http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Observation"
    /// Truth observation.
    case truthObservation = "http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_TruthObservation"

    /// Historical spellings retained as source-compatible aliases.
    public static let category_observation = Self.categoryObservation
    /// Historical spellings retained as source-compatible aliases.
    public static let count_observation = Self.countObservation
    /// Historical spellings retained as source-compatible aliases.
    public static let truth_observation = Self.truthObservation

    /// Decodes one of the five closed OGC values.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var result: Self?
        _ = value.withString { bytes in
            if bytes.equals("http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Category_Observation") {
                result = .categoryObservation
            } else if bytes.equals("http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_CountObservation") {
                result = .countObservation
            } else if bytes.equals("http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Measurement") {
                result = .measurement
            } else if bytes.equals("http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_Observation") {
                result = .observation
            } else if bytes.equals("http://www.opengis.net/def/observationType/OGC-OM/2.0/OM_TruthObservation") {
                result = .truthObservation
            }
        }
        guard let result else { throw .invalidField }
        return result
    }

    /// Encodes the canonical OGC value.
    public borrowing func encode<let capacity: Int>(
        to editor: inout ObjectFieldEncoder<capacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        let literal = rawValue
        do throws(ObjectError) {
            var failure: ObjectError?
            literal.withCString { pointer in
                do throws(ObjectError) {
                    try editor.setEncodedString(key, value: ByteSlice(
                        bytes: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                        length: literal.utf8.count
                    ))
                } catch { failure = error }
            }
            if let failure { throw failure }
        } catch {
            throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

/// A bounded GeoJSON polygon value. The product validates the top-level
/// object/type shape and leaves coordinate winding/closure policy unchanged.
public struct Polygon: ObjectFieldDecodable, ObjectFieldEncodable, Sendable, Equatable {
    private let value: SensorThingsJSONValue

    /// Creates a polygon from a bounded raw JSON object.
    public init(raw: SensorThingsJSONValue) throws(ObjectError) {
        guard raw.kind == .object else { throw ObjectError(.invalidField) }
        var validType = false
        raw.withEncodedBytes { bytes in
            bytes.withBytes { pointer, length in
                let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                if let type = reader.readString("type") { validType = type.equals("Polygon") }
            }
        }
        guard validType else { throw ObjectError(.invalidField) }
        value = raw
    }

    /// Borrows the retained polygon JSON.
    public borrowing func withEncodedBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try value.withEncodedBytes(body)
    }

    /// Decodes a bounded polygon object.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var result: Self?
        value.withRaw { raw in
            guard let json = try? SensorThingsJSONValue(copying: raw) else { return }
            result = try? Self(raw: json)
        }
        guard let result else { throw .invalidField }
        return result
    }

    /// Encodes the polygon as raw JSON.
    public borrowing func encode<let capacity: Int>(
        to editor: inout ObjectFieldEncoder<capacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        try value.encode(to: &editor, forKey: key)
    }
}

/// A four-form SensorThings time interval in millisecond units.
public enum CoatyTimeInterval: ObjectFieldDecodable, ObjectFieldEncodable, Sendable, Equatable {
    /// An interval with start and end timestamps.
    case startEnd(SensorThingsNumber, SensorThingsNumber)
    /// An interval with start timestamp and nonnegative duration.
    case startDuration(SensorThingsNumber, UInt64)
    /// An interval with nonnegative duration and end timestamp.
    case durationEnd(UInt64, SensorThingsNumber)
    /// A duration-only interval.
    case durationOnly(UInt64)

    /// Decodes exactly one of the four supported wire shapes.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        guard value.kind == .object else { throw .invalidField }
        var start: SensorThingsNumber?
        var end: SensorThingsNumber?
        var duration: UInt64?
        var malformed = false
        var valid = false
        value.withRaw { raw in
            raw.withBytes { pointer, length in
                let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                do throws(WireDecodeError) { try reader.validate(); valid = true }
                catch { return }
                if let bytes = reader.readField("_start") {
                    do { start = try SensorThingsNumber(copying: bytes) }
                    catch { malformed = true }
                }
                if let bytes = reader.readField("_end") {
                    do { end = try SensorThingsNumber(copying: bytes) }
                    catch { malformed = true }
                }
                if let bytes = reader.readField("_duration") {
                    do {
                        _ = try JSONValueView.withValidatedRaw(bytes) { view in
                            view.withNumber { number in
                                guard let integer = number.intValue, integer >= 0 else { malformed = true; return }
                                duration = UInt64(integer)
                            }
                        }
                    } catch { malformed = true }
                }
            }
        }
        guard valid, !malformed else { throw .invalidField }
        switch (start, end, duration) {
        case let (.some(start), .some(end), nil): return .startEnd(start, end)
        case let (.some(start), nil, .some(duration)): return .startDuration(start, duration)
        case let (nil, .some(end), .some(duration)): return .durationEnd(duration, end)
        case let (nil, nil, .some(duration)): return .durationOnly(duration)
        default: throw .invalidField
        }
    }

    /// Encodes the selected interval form.
    public borrowing func encode<let capacity: Int>(
        to editor: inout ObjectFieldEncoder<capacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        var nested = ObjectEditor<192>(empty: ())
        func setRaw(_ number: SensorThingsNumber, into editor: inout ObjectEditor<192>, key: StaticString) throws(ObjectError) {
            var failure: ObjectError?
            number.withEncodedBytes { bytes in
                do throws(ObjectError) { try editor.setRaw(key, value: bytes) }
                catch { failure = error }
            }
            if let failure { throw failure }
        }
        do throws(ObjectError) {
            switch self {
            case let .startEnd(start, end):
                try setRaw(start, into: &nested, key: "_start")
                try setRaw(end, into: &nested, key: "_end")
            case let .startDuration(start, duration):
                try setRaw(start, into: &nested, key: "_start")
                try nested.setUnsignedInteger(duration, forKey: "_duration")
            case let .durationEnd(duration, end):
                try nested.setUnsignedInteger(duration, forKey: "_duration")
                try setRaw(end, into: &nested, key: "_end")
            case let .durationOnly(duration):
                try nested.setUnsignedInteger(duration, forKey: "_duration")
            }
            var copyFailure: ObjectError?
            try nested.withEncodedBytes { bytes in
                do throws(ObjectError) { try editor.setRaw(key, value: bytes) }
                catch { copyFailure = error }
            }
            if let copyFailure { throw copyFailure }
        } catch {
            throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField
        }
    }
}

/// A SensorThings FeatureOfInterest value.
public struct FeatureOfInterest: SensorThingsTopLevelSchema, Sendable, Equatable {
    /// Feature description.
    public var description: BoundedEncodedText<128>
    /// Feature metadata encoding type.
    public var encodingType: BoundedEncodedText<128>
    /// Raw feature metadata.
    public var metadata: SensorThingsJSONValue

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<FeatureOfInterest> = sensorThingsSchema(
        "coaty.sensorThings.FeatureOfInterest",
        [("description", required), ("encodingType", required), ("metadata", required)]
    )

    /// Creates a feature of interest.
    public init(
        description: BoundedEncodedText<128>,
        encodingType: BoundedEncodedText<128>,
        metadata: SensorThingsJSONValue
    ) {
        self.description = description
        self.encodingType = encodingType
        self.metadata = metadata
    }

    /// Decodes a feature of interest.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        description = try fields.decode("description", as: BoundedEncodedText<128>.self)
        encodingType = try fields.decode("encodingType", as: BoundedEncodedText<128>.self)
        metadata = try fields.decode("metadata", as: SensorThingsJSONValue.self)
    }

    /// Encodes a feature of interest.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(description, forKey: "description")
        try encoder.encode(encodingType, forKey: "encodingType")
        try encoder.encode(metadata, forKey: "metadata")
    }
}

/// A SensorThings Observation value.
public struct Observation: SensorThingsTopLevelSchema, Sendable, Equatable {
    /// The phenomenon timestamp, retained as a raw JSON number.
    public var phenomenonTime: SensorThingsNumber
    /// Raw observation result JSON.
    public var result: SensorThingsJSONValue
    /// The result timestamp, retained as a raw JSON number.
    public var resultTime: SensorThingsNumber
    /// Optional result quality JSON.
    public var resultQuality: Presence<SensorThingsJSONValue>
    /// Optional valid time interval.
    public var validTime: Presence<CoatyTimeInterval>
    /// Optional parameter JSON.
    public var parameters: Presence<SensorThingsJSONValue>
    /// Optional feature-of-interest identifier.
    public var featureOfInterest: Presence<ObjectID>

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<Observation> = sensorThingsSchema(
        "coaty.sensorThings.Observation",
        [("phenomenonTime", required), ("result", required), ("resultTime", required),
         ("resultQuality", optional), ("validTime", optional), ("parameters", optional),
         ("featureOfInterest", optional)]
    )

    /// Creates an observation.
    public init(
        phenomenonTime: SensorThingsNumber,
        result: SensorThingsJSONValue,
        resultTime: SensorThingsNumber,
        resultQuality: Presence<SensorThingsJSONValue> = .missing,
        validTime: Presence<CoatyTimeInterval> = .missing,
        parameters: Presence<SensorThingsJSONValue> = .missing,
        featureOfInterest: Presence<ObjectID> = .missing
    ) {
        self.phenomenonTime = phenomenonTime
        self.result = result
        self.resultTime = resultTime
        self.resultQuality = resultQuality
        self.validTime = validTime
        self.parameters = parameters
        self.featureOfInterest = featureOfInterest
    }

    /// Decodes an observation. The canonical `phenomenonTime` field is
    /// required; the historical `phenomenonType` fallback is specific to
    /// Sensor and is not accepted for Observation values.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        phenomenonTime = try fields.decode("phenomenonTime", as: SensorThingsNumber.self)
        result = try fields.decode("result", as: SensorThingsJSONValue.self)
        resultTime = try fields.decode("resultTime", as: SensorThingsNumber.self)
        resultQuality = try fields.presence("resultQuality", as: SensorThingsJSONValue.self)
        validTime = try fields.presence("validTime", as: CoatyTimeInterval.self)
        parameters = try fields.presence("parameters", as: SensorThingsJSONValue.self)
        featureOfInterest = try fields.presence("featureOfInterest", as: ObjectID.self)
    }

    /// Encodes the canonical observation fields.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(phenomenonTime, forKey: "phenomenonTime")
        try encoder.encode(result, forKey: "result")
        try encoder.encode(resultTime, forKey: "resultTime")
        try encoder.encode(resultQuality, forKey: "resultQuality")
        try encoder.encode(validTime, forKey: "validTime")
        try encoder.encode(parameters, forKey: "parameters")
        try encoder.encode(featureOfInterest, forKey: "featureOfInterest")
    }
}

/// A SensorThings Sensor value.
public struct Sensor: SensorThingsTopLevelSchema, Sendable, Equatable {
    /// Sensor description.
    public var description: BoundedEncodedText<128>
    /// Sensor metadata encoding type.
    public var encodingType: BoundedEncodedText<128>
    /// Raw sensor metadata.
    public var metadata: SensorThingsJSONValue
    /// Sensor unit of measurement.
    public var unitOfMeasurement: UnitOfMeasurement
    /// Closed observation result type.
    public var observationType: ObservationType
    /// Optional observed area.
    public var observedArea: Presence<Polygon>
    /// Optional phenomenon-time extent.
    public var phenomenonTime: Presence<CoatyTimeInterval>
    /// Optional result-time extent.
    public var resultTime: Presence<CoatyTimeInterval>
    /// Shared observed property.
    public var observedProperty: ObservedProperty

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<Sensor> = sensorThingsSchema(
        "coaty.sensorThings.Sensor",
        [("description", required), ("encodingType", required), ("metadata", required),
         ("unitOfMeasurement", required), ("observationType", required), ("observedArea", optional),
         ("phenomenonTime", optional), ("resultTime", optional), ("observedProperty", required)]
    )

    /// Creates a sensor value.
    public init(
        description: BoundedEncodedText<128>,
        encodingType: BoundedEncodedText<128>,
        metadata: SensorThingsJSONValue,
        unitOfMeasurement: UnitOfMeasurement,
        observationType: ObservationType,
        observedArea: Presence<Polygon> = .missing,
        phenomenonTime: Presence<CoatyTimeInterval> = .missing,
        resultTime: Presence<CoatyTimeInterval> = .missing,
        observedProperty: ObservedProperty
    ) {
        self.description = description
        self.encodingType = encodingType
        self.metadata = metadata
        self.unitOfMeasurement = unitOfMeasurement
        self.observationType = observationType
        self.observedArea = observedArea
        self.phenomenonTime = phenomenonTime
        self.resultTime = resultTime
        self.observedProperty = observedProperty
    }

    /// Decodes a sensor and accepts the historical `phenomenonType` fallback.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        description = try fields.decode("description", as: BoundedEncodedText<128>.self)
        encodingType = try fields.decode("encodingType", as: BoundedEncodedText<128>.self)
        metadata = try fields.decode("metadata", as: SensorThingsJSONValue.self)
        unitOfMeasurement = try fields.decode("unitOfMeasurement", as: UnitOfMeasurement.self)
        observationType = try fields.decode("observationType", as: ObservationType.self)
        observedArea = try fields.presence("observedArea", as: Polygon.self)
        let canonical = try fields.presence("phenomenonTime", as: CoatyTimeInterval.self)
        phenomenonTime = canonical == .missing
            ? try fields.presence("phenomenonType", as: CoatyTimeInterval.self)
            : canonical
        resultTime = try fields.presence("resultTime", as: CoatyTimeInterval.self)
        observedProperty = try fields.decode("observedProperty", as: ObservedProperty.self)
    }

    /// Encodes canonical SensorThings Sensor fields.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(description, forKey: "description")
        try encoder.encode(encodingType, forKey: "encodingType")
        try encoder.encode(metadata, forKey: "metadata")
        try encoder.encode(unitOfMeasurement, forKey: "unitOfMeasurement")
        try encoder.encode(observationType, forKey: "observationType")
        try encoder.encode(observedArea, forKey: "observedArea")
        try encoder.encode(phenomenonTime, forKey: "phenomenonTime")
        try encoder.encode(resultTime, forKey: "resultTime")
        try encoder.encode(observedProperty, forKey: "observedProperty")
    }
}

/// A SensorThings Thing value with heterogeneous JSON properties.
public struct Thing: SensorThingsTopLevelSchema, Sendable, Equatable {
    /// Thing description.
    public var description: BoundedEncodedText<128>
    /// Optional JSON object of application properties.
    public var properties: Presence<SensorThingsJSONValue>

    /// The fixed SensorThings schema descriptor.
    public static let schema: PortableObjectSchema<Thing> = sensorThingsSchema(
        "coaty.sensorThings.Thing",
        [("description", required), ("properties", optional)]
    )

    /// Creates a Thing value.
    public init(
        description: BoundedEncodedText<128>,
        properties: Presence<SensorThingsJSONValue> = .missing
    ) throws(ObjectError) {
        if case let .value(properties) = properties, properties.kind != .object {
            throw ObjectError(.invalidField)
        }
        self.description = description
        self.properties = properties
    }

    /// Decodes a Thing and validates that properties is an object when present.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        description = try fields.decode("description", as: BoundedEncodedText<128>.self)
        let properties = try fields.presence("properties", as: SensorThingsJSONValue.self)
        if case let .value(properties) = properties, properties.kind != .object {
            throw .invalidField
        }
        self.properties = properties
    }

    /// Encodes a Thing.
    public borrowing func encodeFields<let capacity: Int>(
        to encoder: inout ObjectFieldEncoder<capacity>
    ) throws(ObjectEncodingError) {
        try encoder.encode(description, forKey: "description")
        try encoder.encode(properties, forKey: "properties")
    }
}


extension UnitOfMeasurement: ObjectFieldDecodable, ObjectFieldEncodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        do { return try value.decode(Self.self) }
        catch { throw .invalidField }
    }

    public borrowing func encode<let capacity: Int>(
        to editor: inout ObjectFieldEncoder<capacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        if let rawSnapshot {
            try rawSnapshot.encode(to: &editor, forKey: key)
        } else {
            try encodeNested(self, to: &editor, forKey: key)
        }
    }
}

extension ObservedProperty: ObjectFieldDecodable, ObjectFieldEncodable {
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        do { return try value.decode(Self.self) }
        catch { throw .invalidField }
    }

    public borrowing func encode<let capacity: Int>(
        to editor: inout ObjectFieldEncoder<capacity>,
        forKey key: StaticString
    ) throws(ObjectEncodingError) {
        if let rawSnapshot {
            try rawSnapshot.encode(to: &editor, forKey: key)
        } else {
            try encodeNested(self, to: &editor, forKey: key)
        }
    }
}

private func encodeNested<Schema: ObjectSchema, let capacity: Int>(
    _ value: borrowing Schema,
    to editor: inout ObjectFieldEncoder<capacity>,
    forKey key: StaticString
) throws(ObjectEncodingError) {
    var nested = ObjectEditor<256>(empty: ())
    do throws(ObjectEncodingError) {
        try value.encodeFields(to: &nested)
    } catch {
        throw error
    }
    var failure: ObjectError?
    do throws(ObjectError) {
        try nested.withEncodedBytes { raw in
            do throws(ObjectError) { try editor.setRaw(key, value: raw) }
            catch { failure = error }
        }
    } catch {
        failure = error
    }
    if let failure {
        throw failure.reason == .capacityExceeded ? .capacityExceeded : .invalidField
    }
}
