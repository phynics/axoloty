// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// The representation negotiated for an IO endpoint.
public enum IoValueRepresentation: UInt8, Sendable, Equatable, Hashable {
    /// A JSON-encoded endpoint payload.
    case json
    /// A binary endpoint payload.
    case binary
}

/// A stable semantic application value type.
public struct IoValueType: Sendable, Equatable, Hashable {
    private let value: BoundedEncodedText<128>
    /// Creates a type identifier from a bounded literal.
    public init(_ literal: StaticString) throws(ProtocolError) {
        guard let value = BoundedEncodedText<128>(literal), value.length > 0 else { throw ProtocolError(.malformedPayload) }
        self.value = value
    }
    /// Copies a type identifier from bytes.
    public init(bytes: ByteSlice) throws(ProtocolError) {
        guard let value = BoundedEncodedText<128>(bytes: bytes), value.length > 0 else { throw ProtocolError(.malformedPayload) }
        self.value = value
    }
    /// Compares the identifier with a static spelling.
    public borrowing func equals(_ literal: StaticString) -> Bool { value.encodedEquals(literal) }
    /// Borrows the identifier bytes.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) -> R) -> R { value.withBytes(body) }
    /// Copies an existing bounded identifier.
    public init(copying value: borrowing BoundedEncodedText<128>) throws(ProtocolError) {
        var result: Self?
        value.withBytes { bytes in result = try? Self(bytes: bytes) }
        guard let result else { throw ProtocolError(.malformedPayload) }
        self = result
    }
    /// Encodes the identifier into an object field.
    public borrowing func encodeField<let capacity: Int>(to editor: inout ObjectFieldEncoder<capacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do throws(ObjectError) { try value.encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension IoValueType: ObjectFieldEncodable {
    /// Encodes the semantic value type into one object field.
    public borrowing func encode<let capacity: Int>(to editor: inout ObjectFieldEncoder<capacity>, forKey key: StaticString) throws(ObjectEncodingError) {
        do throws(ObjectError) { try value.encodeField(key, to: &editor) }
        catch { throw error.reason == .capacityExceeded ? .capacityExceeded : .invalidField }
    }
}

extension IoValueType: ObjectFieldDecodable {
    /// Decodes a semantic value type from one JSON string field.
    public static func decode(from value: borrowing JSONValueView) throws(ObjectDecodingError) -> Self {
        var result: Self?
        guard value.withString({ bytes in result = try? Self(bytes: bytes) }), let result else { throw .invalidField }
        return result
    }
}

/// A bounded owned byte value.
public struct BoundedIoBytes<let capacity: Int>: Sendable, Equatable {
    private var storage: InlineArray<capacity, UInt8>
    /// Number of retained bytes.
    public private(set) var length: Int
    /// Creates an empty value.
    public init() { storage = InlineArray(repeating: 0); length = 0 }
    /// Copies bytes into bounded storage.
    public init(copying bytes: ByteSlice) throws(ProtocolError) {
        guard bytes.length <= capacity else { throw ProtocolError(.capacityExceeded) }
        storage = InlineArray(repeating: 0); length = bytes.length
        for index in 0..<length { storage[index] = bytes.byte(at: index)! }
    }
    /// Borrows the retained bytes.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) throws -> R) rethrows -> R {
        let localLength = length
        return try withUnsafeBytes(of: storage) { buffer in
            try body(ByteSlice(
                bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                length: localLength
            ))
        }
    }
    /// Compares two bounded payloads byte-for-byte.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.length == rhs.length else { return false }
        for index in 0..<lhs.length where lhs.storage[index] != rhs.storage[index] { return false }
        return true
    }
}

/// A bounded JSON payload.
public typealias BoundedJSONValue<let capacity: Int> = BoundedIoBytes<capacity>

/// Structured IO value failures.
public enum IoValueError: UInt8, Error, Sendable, Equatable {
    /// The payload does not match the endpoint value.
    case invalidValue
    /// The bounded payload storage was insufficient.
    case capacityExceeded
}

/// A value that can be decoded and encoded at a registered IO endpoint.
public protocol IoEndpointValue: Sendable {
    /// The representation fixed by the value type, or `nil` when registration
    /// fixes it for a dynamic value.
    static var fixedRepresentation: IoValueRepresentation? { get }

    /// Decodes one complete endpoint payload.
    ///
    /// - Parameters:
    ///   - payload: Complete borrowed payload bytes.
    ///   - representation: Representation fixed by endpoint registration.
    /// - Returns: The decoded application value.
    /// - Throws: ``IoValueError`` when the representation or payload is invalid.
    static func decodeIoPayload(
        _ payload: borrowing ByteSlice,
        representation: IoValueRepresentation
    ) throws(IoValueError) -> Self

    /// Encodes one complete endpoint payload for a synchronous visitor.
    ///
    /// - Parameters:
    ///   - representation: Representation fixed by endpoint registration.
    ///   - body: Nonescaping visitor for the encoded bytes.
    /// - Returns: The visitor result.
    /// - Throws: ``IoValueError`` or an error thrown by `body`.
    borrowing func withEncodedIoPayload<R>(
        representation: IoValueRepresentation,
        _ body: (borrowing ByteSlice) throws -> R
    ) throws -> R
}

/// Common portable IO value contract with a type-fixed representation.
public protocol IoValue: IoEndpointValue {
    /// Representation fixed by the application value type.
    static var representation: IoValueRepresentation { get }
}

/// JSON IO value contract.
public protocol JSONIoValue: IoValue {
    /// Decodes a validated borrowed JSON value.
    ///
    /// - Parameter value: Validated JSON bytes borrowed for the initializer call.
    /// - Throws: ``IoValueError`` when the JSON value cannot initialize this type.
    init(ioJSON value: borrowing JSONValueView) throws(IoValueError)

    /// Encodes this value into bounded JSON output.
    ///
    /// - Parameter output: Destination for one complete JSON value.
    /// - Throws: ``IoValueError`` when encoding fails or exceeds the output capacity.
    borrowing func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError)
}
/// Binary IO value contract.
public protocol BinaryIoValue: IoValue {
    /// Decodes borrowed binary payload bytes.
    ///
    /// - Parameter ioBytes: Complete payload bytes borrowed for the initializer call.
    /// - Throws: ``IoValueError`` when the bytes cannot initialize this type.
    init(ioBytes: borrowing ByteSlice) throws(IoValueError)

    /// Encodes this value into bounded binary output.
    ///
    /// - Parameter output: Destination for one complete binary payload.
    /// - Throws: ``IoValueError`` when encoding fails or exceeds the output capacity.
    borrowing func encodeIoBytes(into output: inout IoByteOutput) throws(IoValueError)
}
extension IoValue {
    /// Representation fixed by the conforming value type.
    public static var fixedRepresentation: IoValueRepresentation? { representation }
}

extension JSONIoValue {
    /// JSON representation supplied by the refinement.
    public static var representation: IoValueRepresentation { .json }

    /// Decodes a complete JSON endpoint payload.
    ///
    /// - Parameters:
    ///   - payload: Complete borrowed JSON payload bytes.
    ///   - representation: Representation selected during endpoint registration.
    /// - Returns: The decoded application value.
    /// - Throws: ``IoValueError`` when the representation or payload is invalid.
    public static func decodeIoPayload(
        _ payload: borrowing ByteSlice,
        representation: IoValueRepresentation
    ) throws(IoValueError) -> Self {
        guard representation == .json else { throw .invalidValue }
        var decoded: Self?
        var failure: IoValueError?
        do throws(ObjectError) {
            try JSONValueView.withValidatedRaw(payload) { view in
                do throws(IoValueError) { decoded = try Self(ioJSON: view) }
                catch { failure = error }
            }
        } catch {
            throw .invalidValue
        }
        if let failure { throw failure }
        guard let decoded else { throw .invalidValue }
        return decoded
    }

    /// Encodes a JSON endpoint payload for a synchronous visitor.
    ///
    /// - Parameters:
    ///   - representation: Representation selected during endpoint registration.
    ///   - body: Nonescaping visitor for the encoded payload bytes.
    /// - Returns: The visitor result.
    /// - Throws: ``IoValueError`` or an error thrown by `body`.
    public borrowing func withEncodedIoPayload<R>(
        representation: IoValueRepresentation,
        _ body: (borrowing ByteSlice) throws -> R
    ) throws -> R {
        guard representation == .json else { throw IoValueError.invalidValue }
        var output = IoJSONOutput()
        try encodeIoJSON(into: &output)
        return try output.withBytes(body)
    }
}

extension BinaryIoValue {
    /// Binary representation supplied by the refinement.
    public static var representation: IoValueRepresentation { .binary }

    /// Decodes a complete binary endpoint payload.
    ///
    /// - Parameters:
    ///   - payload: Complete borrowed binary payload bytes.
    ///   - representation: Representation selected during endpoint registration.
    /// - Returns: The decoded application value.
    /// - Throws: ``IoValueError`` when the representation or payload is invalid.
    public static func decodeIoPayload(
        _ payload: borrowing ByteSlice,
        representation: IoValueRepresentation
    ) throws(IoValueError) -> Self {
        guard representation == .binary else { throw .invalidValue }
        return try Self(ioBytes: payload)
    }

    /// Encodes a binary endpoint payload for a synchronous visitor.
    ///
    /// - Parameters:
    ///   - representation: Representation selected during endpoint registration.
    ///   - body: Nonescaping visitor for the encoded payload bytes.
    /// - Returns: The visitor result.
    /// - Throws: ``IoValueError`` or an error thrown by `body`.
    public borrowing func withEncodedIoPayload<R>(
        representation: IoValueRepresentation,
        _ body: (borrowing ByteSlice) throws -> R
    ) throws -> R {
        guard representation == .binary else { throw IoValueError.invalidValue }
        var output = IoByteOutput()
        try encodeIoBytes(into: &output)
        return try output.withBytes(body)
    }
}

/// A fixed-capacity JSON writer.
public struct IoJSONOutput: ~Copyable, Sendable {
    private var value: BoundedJSONValue<2048> = BoundedJSONValue()

    /// Creates an empty bounded JSON output.
    public init() {}

    /// Copies one complete JSON value.
    ///
    /// - Parameter bytes: Complete validated or unvalidated JSON value bytes.
    /// - Throws: ``IoValueError`` when the bytes are invalid or exceed capacity.
    public mutating func writeRaw(_ bytes: ByteSlice) throws(IoValueError) {
        do throws(ProtocolError) { value = try BoundedJSONValue(copying: bytes) }
        catch { throw error.code == .capacityExceeded ? .capacityExceeded : .invalidValue }
    }
    /// Writes a static JSON literal.
    ///
    /// - Parameter literal: Complete static JSON literal to copy.
    /// - Throws: ``IoValueError`` when the literal is invalid or exceeds capacity.
    public mutating func write(_ literal: StaticString) throws(IoValueError) { try writeRaw(ByteSlice(bytes: literal.utf8Start, length: literal.utf8CodeUnitCount)) }
    /// Borrows the encoded value.
    ///
    /// - Parameter body: Nonescaping visitor for the encoded bytes.
    /// - Returns: The visitor result.
    /// - Throws: An error thrown by `body`.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) throws -> R) rethrows -> R { try value.withBytes(body) }
    /// Finishes the output.
    ///
    /// - Returns: The complete bounded JSON value.
    public consuming func finish() -> BoundedJSONValue<2048> { value }
}

/// A fixed-capacity binary writer.
public struct IoByteOutput: ~Copyable, Sendable {
    private var value: BoundedIoBytes<2048> = BoundedIoBytes()

    /// Creates an empty bounded binary output.
    public init() {}

    /// Copies bytes into the output.
    ///
    /// - Parameter bytes: Complete binary payload bytes to copy.
    /// - Throws: ``IoValueError`` when the payload exceeds capacity.
    public mutating func write(_ bytes: ByteSlice) throws(IoValueError) {
        do throws(ProtocolError) { value = try BoundedIoBytes(copying: bytes) }
        catch { throw error.code == .capacityExceeded ? .capacityExceeded : .invalidValue }
    }
    /// Borrows the encoded value.
    ///
    /// - Parameter body: Nonescaping visitor for the encoded bytes.
    /// - Returns: The visitor result.
    /// - Throws: An error thrown by `body`.
    public borrowing func withBytes<R>(_ body: (borrowing ByteSlice) throws -> R) rethrows -> R { try value.withBytes(body) }
    /// Finishes the output.
    ///
    /// - Returns: The complete bounded binary payload.
    public consuming func finish() -> BoundedIoBytes<2048> { value }
}

/// A dynamic endpoint value with a fixed registration-time representation.
public enum DynamicIoValue: IoEndpointValue, Equatable {
    /// A bounded JSON payload.
    case json(BoundedJSONValue<2048>)
    /// A bounded binary payload.
    case binary(BoundedIoBytes<2048>)
    /// Returns the carried representation.
    public var representation: IoValueRepresentation { switch self { case .json: return .json; case .binary: return .binary } }

    /// Dynamic values fix their accepted representation during registration.
    public static var fixedRepresentation: IoValueRepresentation? { nil }

    /// Copies a complete payload into the selected bounded dynamic case.
    public static func decodeIoPayload(
        _ payload: borrowing ByteSlice,
        representation: IoValueRepresentation
    ) throws(IoValueError) -> Self {
        do throws(ProtocolError) {
            switch representation {
            case .json:
                guard WireReader.isValidJSONValue(payload) else {
                    throw ProtocolError(.malformedPayload)
                }
                return .json(try BoundedJSONValue(copying: payload))
            case .binary:
                return .binary(try BoundedIoBytes(copying: payload))
            }
        } catch {
            throw error.code == .capacityExceeded ? .capacityExceeded : .invalidValue
        }
    }

    /// Borrows the selected dynamic case after representation validation.
    public borrowing func withEncodedIoPayload<R>(
        representation: IoValueRepresentation,
        _ body: (borrowing ByteSlice) throws -> R
    ) throws -> R {
        switch (copy self, representation) {
        case (.json(let value), .json), (.binary(let value), .binary):
            return try value.withBytes(body)
        default:
            throw IoValueError.invalidValue
        }
    }
}

/// Public route classification used by typed IO delivery handlers.
public enum IoRouteKind: UInt8, Sendable, Equatable {
    /// A generated Coaty IO value route.
    case coaty
    /// A validated exact transport-binding route.
    case external
}

/// Complete typed IO actor delivery context.
public struct IoDeliveryContext: Sendable, Equatable {
    /// Source endpoint identity.
    public let sourceID: ObjectID
    /// Actor endpoint identity.
    public let actorID: ObjectID
    /// Caller-supplied monotonic receive time.
    public let receivedAtMS: UInt32
    /// Processor association generation observed for delivery.
    public let associationGeneration: UInt32
    /// Public classification without exposing route bytes.
    public let routeKind: IoRouteKind

    /// Creates a complete typed delivery context.
    public init(
        sourceID: ObjectID,
        actorID: ObjectID,
        receivedAtMS: UInt32,
        associationGeneration: UInt32,
        routeKind: IoRouteKind
    ) {
        self.sourceID = sourceID
        self.actorID = actorID
        self.receivedAtMS = receivedAtMS
        self.associationGeneration = associationGeneration
        self.routeKind = routeKind
    }

    /// Creates delivery context from portable protocol UUIDs.
    ///
    /// This initializer is intended for runtime adapters that already hold
    /// normalized protocol endpoint identities.
    ///
    /// - Parameters:
    ///   - sourceUUID: Source endpoint UUID.
    ///   - actorUUID: Actor endpoint UUID.
    ///   - receivedAtMS: Caller-supplied monotonic receive time.
    ///   - associationGeneration: Processor association generation.
    ///   - routeKind: Public route classification.
    public init(
        sourceUUID: UUID16,
        actorUUID: UUID16,
        receivedAtMS: UInt32,
        associationGeneration: UInt32,
        routeKind: IoRouteKind
    ) {
        self.init(
            sourceID: ObjectID(uuid: sourceUUID),
            actorID: ObjectID(uuid: actorUUID),
            receivedAtMS: receivedAtMS,
            associationGeneration: associationGeneration,
            routeKind: routeKind
        )
    }
}

/// Source publication policy.
public enum IoPublicationPolicy: Sendable, Equatable {
    /// Publishes every value admitted by the processor.
    case immediate
    /// Publishes immediately when eligible and retains one replacement.
    case latest(atMostEveryMS: UInt32)
    /// Publishes only when the policy interval is eligible.
    case throttle(forMS: UInt32)
}
/// Publication admission result.
public enum IoPublicationReceipt: Sendable, Equatable {
    /// The current value was accepted for publication.
    case published
    /// A latest replacement was retained.
    case queuedLatest
    /// The value was constrained by the effective interval.
    case throttled
    /// No active association accepted the value.
    case notAssociated
    /// The processor rejected the value.
    case rejected(ProtocolError.Code)
}

/// Public association snapshot.
public struct IoAssociationState: Sendable, Equatable {
    /// Processor generation at which this snapshot was observed.
    public let generation: UInt32
    /// Whether at least one association is active.
    public let hasAssociations: Bool
    /// Number of active associations matching the endpoint.
    public let associationCount: Int
    /// Maximum recommended update rate among active associations.
    public let recommendedUpdateRateMS: UInt32?
    /// Creates an association snapshot.
    public init(generation: UInt32 = 0, hasAssociations: Bool = false, associationCount: Int = 0, recommendedUpdateRateMS: UInt32? = nil) {
        self.generation = generation; self.hasAssociations = hasAssociations; self.associationCount = associationCount; self.recommendedUpdateRateMS = recommendedUpdateRateMS
    }
}

/// Copyable typed source registry key.
public struct IoSource<Value: IoEndpointValue>: Sendable, Hashable {
    private let registryID: ObjectID
    private let slot: UInt16
    private let generation: UInt32
    private let representation: IoValueRepresentation
    /// Public endpoint identity.
    public let id: ObjectID

    /// Creates a provenance-complete handle for a runtime adapter.
    ///
    /// Application code receives handles from endpoint registration and does
    /// not construct them directly.
    // The AxolotyRuntimeAdapter SPI stays an SPI here, unlike the host runtime's
// equivalent surface, which is now `package`. AxolotyStaticRuntime consumes
// these declarations and is compiled for Embedded Swift through ESP-IDF CMake
// components that pass `-module-name` without `-package-name`, so `package`
// would not cross that boundary. Converting it means adding that flag to the
// embedded components -- the mechanism exists, `json_core` already does it --
// and verifying on hardware.

@_spi(AxolotyRuntimeAdapter)
    public init(
        registryID: ObjectID,
        slot: UInt16,
        generation: UInt32,
        id: ObjectID,
        representation: IoValueRepresentation
    ) {
        self.registryID = registryID
        self.slot = slot
        self.generation = generation
        self.id = id
        self.representation = representation
    }

    /// Tests every opaque provenance component against a registry record.
    @_spi(AxolotyRuntimeAdapter)
    public borrowing func matches(
        registryID: ObjectID,
        slot: UInt16,
        generation: UInt32,
        id: ObjectID,
        representation: IoValueRepresentation
    ) -> Bool {
        guard self.registryID == registryID else { return false }
        guard self.slot == slot else { return false }
        guard self.generation == generation else { return false }
        guard self.id == id else { return false }
        return self.representation == representation
    }

    /// Returns the opaque slot for bounded runtime validation.
    @_spi(AxolotyRuntimeAdapter)
    public var runtimeSlot: UInt16 { slot }

    /// Compares two source handles including their hidden provenance.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && lhs.slot == rhs.slot &&
            lhs.generation == rhs.generation && lhs.id == rhs.id &&
            lhs.representation == rhs.representation
    }
    /// Hashes the complete source handle provenance.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(registryID); hasher.combine(slot); hasher.combine(generation)
        hasher.combine(id); hasher.combine(representation)
    }
}
/// Copyable typed actor registry key.
public struct IoActor<Value: IoEndpointValue>: Sendable, Hashable {
    private let registryID: ObjectID
    private let slot: UInt16
    private let generation: UInt32
    private let representation: IoValueRepresentation
    /// Public endpoint identity.
    public let id: ObjectID

    /// Creates a provenance-complete handle for a runtime adapter.
    ///
    /// Application code receives handles from endpoint registration and does
    /// not construct them directly.
    @_spi(AxolotyRuntimeAdapter)
    public init(
        registryID: ObjectID,
        slot: UInt16,
        generation: UInt32,
        id: ObjectID,
        representation: IoValueRepresentation
    ) {
        self.registryID = registryID
        self.slot = slot
        self.generation = generation
        self.id = id
        self.representation = representation
    }

    /// Tests every opaque provenance component against a registry record.
    @_spi(AxolotyRuntimeAdapter)
    public borrowing func matches(
        registryID: ObjectID,
        slot: UInt16,
        generation: UInt32,
        id: ObjectID,
        representation: IoValueRepresentation
    ) -> Bool {
        guard self.registryID == registryID else { return false }
        guard self.slot == slot else { return false }
        guard self.generation == generation else { return false }
        guard self.id == id else { return false }
        return self.representation == representation
    }

    /// Returns the opaque slot for bounded runtime validation.
    @_spi(AxolotyRuntimeAdapter)
    public var runtimeSlot: UInt16 { slot }

    /// Compares two actor handles including their hidden provenance.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && lhs.slot == rhs.slot &&
            lhs.generation == rhs.generation && lhs.id == rhs.id &&
            lhs.representation == rhs.representation
    }
    /// Hashes the complete actor handle provenance.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(registryID); hasher.combine(slot); hasher.combine(generation)
        hasher.combine(id); hasher.combine(representation)
    }
}

/// Portable source metadata; policy fields are derived by the runtime builder.
public struct IoSourceMetadata: ObjectSchema, Sendable {
    /// Semantic value type owned by the endpoint metadata.
    public let valueType: IoValueType
    var updateStrategy: UInt64?
    var useRawIoValues: Bool?
    var updateRate: UInt64?
    var externalRoute: BoundedEncodedText<256>?
    /// Schema descriptor for a source endpoint.
    public static let schema = ioMetadataSchema(IoSourceMetadata.self, objectType: "coaty.IoSource", coreType: .ioSource, actor: false)
    /// Creates source metadata with no runtime-derived fields.
    public init(valueType: IoValueType) {
        self.valueType = valueType; updateStrategy = nil; useRawIoValues = nil
        updateRate = nil; externalRoute = nil
    }
    /// Decodes source metadata from object fields.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        valueType = try fields.decode("valueType", as: IoValueType.self)
        updateStrategy = try fields.decodeIfPresent("updateStrategy", as: UInt64.self)
        useRawIoValues = try fields.decodeIfPresent("useRawIoValues", as: Bool.self)
        updateRate = try fields.decodeIfPresent("updateRate", as: UInt64.self)
        externalRoute = try fields.decodeIfPresent("externalRoute", as: BoundedEncodedText<256>.self)
    }
    /// Encodes source metadata fields.
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) {
        try encoder.encode(valueType, forKey: "valueType")
        try encoder.encode(updateStrategy, forKey: "updateStrategy")
        try encoder.encode(useRawIoValues, forKey: "useRawIoValues")
        try encoder.encode(updateRate, forKey: "updateRate")
        try encoder.encode(externalRoute, forKey: "externalRoute")
    }
}
/// Portable actor metadata; policy fields are derived by the runtime builder.
public struct IoActorMetadata: ObjectSchema, Sendable {
    /// Semantic value type owned by the endpoint metadata.
    public let valueType: IoValueType
    var useRawIoValues: Bool?
    var updateRate: UInt64?
    var externalRoute: BoundedEncodedText<256>?
    /// Schema descriptor for an actor endpoint.
    public static let schema = ioMetadataSchema(IoActorMetadata.self, objectType: "coaty.IoActor", coreType: .ioActor, actor: true)
    /// Creates actor metadata with no runtime-derived fields.
    public init(valueType: IoValueType) {
        self.valueType = valueType; useRawIoValues = nil; updateRate = nil; externalRoute = nil
    }
    /// Decodes actor metadata from object fields.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {
        valueType = try fields.decode("valueType", as: IoValueType.self)
        useRawIoValues = try fields.decodeIfPresent("useRawIoValues", as: Bool.self)
        updateRate = try fields.decodeIfPresent("updateRate", as: UInt64.self)
        externalRoute = try fields.decodeIfPresent("externalRoute", as: BoundedEncodedText<256>.self)
    }
    /// Encodes actor metadata fields.
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) {
        try encoder.encode(valueType, forKey: "valueType")
        try encoder.encode(useRawIoValues, forKey: "useRawIoValues")
        try encoder.encode(updateRate, forKey: "updateRate")
        try encoder.encode(externalRoute, forKey: "externalRoute")
    }
}

private func ioMetadataSchema<Value: Sendable>(_ type: Value.Type, objectType: StaticString, coreType: ObjectCoreType, actor: Bool) -> PortableObjectSchema<Value> {
    var fields = InlineArray<24, ObjectFieldDescriptor>(repeating: .empty)
    fields[0] = ObjectFieldDescriptor(key: ObjectFieldKey("valueType")!, index: 0, flags: .required)
    if actor {
        fields[1] = ObjectFieldDescriptor(key: ObjectFieldKey("useRawIoValues")!, index: 1, flags: .optional)
        fields[2] = ObjectFieldDescriptor(key: ObjectFieldKey("updateRate")!, index: 2, flags: .optional)
        fields[3] = ObjectFieldDescriptor(key: ObjectFieldKey("externalRoute")!, index: 3, flags: .optional)
        return PortableObjectSchema(objectType: ObjectType(objectType)!, coreType: coreType, fieldCount: 4, fields: fields)
    }
    fields[1] = ObjectFieldDescriptor(key: ObjectFieldKey("updateStrategy")!, index: 1, flags: .optional)
    fields[2] = ObjectFieldDescriptor(key: ObjectFieldKey("useRawIoValues")!, index: 2, flags: .optional)
    fields[3] = ObjectFieldDescriptor(key: ObjectFieldKey("updateRate")!, index: 3, flags: .optional)
    fields[4] = ObjectFieldDescriptor(key: ObjectFieldKey("externalRoute")!, index: 4, flags: .optional)
    return PortableObjectSchema(objectType: ObjectType(objectType)!, coreType: coreType, fieldCount: 5, fields: fields)
}
/// Portable IO context metadata.
public struct IoContext: ObjectSchema, Sendable {
    /// Schema descriptor for an empty IO context.
    public static let schema = PortableObjectSchema<IoContext>(objectType: ObjectType("coaty.IoContext")!, coreType: .ioContext, fieldCount: 0, fields: InlineArray<24, ObjectFieldDescriptor>(repeating: .empty))
    /// Creates an empty IO context.
    public init() {}
    /// Decodes an empty IO context.
    public init(decoding fields: borrowing ObjectFieldDecoder) throws(ObjectDecodingError) {}
    /// Encodes an empty IO context.
    public borrowing func encodeFields<let capacity: Int>(to encoder: inout ObjectFieldEncoder<capacity>) throws(ObjectEncodingError) {}
}
