// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// A consumed and normalized source endpoint definition.
public struct IoSourceEndpointDefinition: ~Copyable, Sendable {
    /// Endpoint object identity.
    public let id: ObjectID
    /// Payload representation fixed during registration.
    public let representation: IoValueRepresentation
    /// Publication policy encoded into the canonical object.
    public let publication: IoPublicationPolicy
    private let objectBytes: BoundedIoBytes<512>

    /// Consumes source metadata and derives its runtime-owned wire fields.
    ///
    /// - Parameters:
    ///   - metadata: Validated typed source object to consume.
    ///   - representation: Representation fixed for the endpoint.
    ///   - publication: Local source publication policy.
    /// - Throws: ``ProtocolError`` when normalization or bounded copying fails.
    public init(
        metadata: consuming Object<IoSourceMetadata>,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy
    ) throws(ProtocolError) {
        try self.init(
            metadata: metadata,
            representation: representation,
            publication: publication,
            externalRoute: nil
        )
    }

    /// Runtime adapter initializer that preserves one validated external
    /// route in the consumed canonical object.
    ///
    /// - Parameters:
    ///   - metadata: Validated typed source object to consume.
    ///   - representation: Representation fixed for the endpoint.
    ///   - publication: Local source publication policy.
    ///   - externalRoute: Optional validated route to preserve in the object.
    /// - Throws: ``ProtocolError`` when normalization or bounded copying fails.
    @_spi(AxolotyRuntimeAdapter)
    public init(
        metadata: consuming Object<IoSourceMetadata>,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy,
        externalRoute: BoundedEncodedText<128>?
    ) throws(ProtocolError) {
        var object = metadata
        var boundedExternalRoute: BoundedEncodedText<128>?
        if let externalRoute {
            externalRoute.withBytes { bytes in
                boundedExternalRoute = BoundedEncodedText<128>(bytes: bytes)
            }
            guard boundedExternalRoute != nil else {
                throw ProtocolError(.capacityExceeded)
            }
        }
        do throws(ObjectError) {
            try object.edit { fields in
                fields.useRawIoValues = representation == .binary ? true : nil
                fields.externalRoute = boundedExternalRoute
                switch publication {
                case .immediate:
                    fields.updateStrategy = 1
                    fields.updateRate = nil
                case .latest(let interval):
                    fields.updateStrategy = 2
                    fields.updateRate = UInt64(interval)
                case .throttle(let interval):
                    fields.updateStrategy = 3
                    fields.updateRate = UInt64(interval)
                }
            }
        } catch {
            throw protocolError(error)
        }

        let snapshot = try endpointSnapshot(of: object)
        id = snapshot.id
        objectBytes = snapshot.bytes
        self.representation = representation
        self.publication = publication
    }

    /// Borrows the normalized canonical object bytes synchronously.
    ///
    /// - Parameter body: Nonescaping visitor for the canonical object.
    /// - Returns: The visitor result.
    /// - Throws: An error thrown by `body`.
    public borrowing func withObjectBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try objectBytes.withBytes(body)
    }
}

/// A consumed and normalized actor endpoint definition.
public struct IoActorEndpointDefinition: ~Copyable, Sendable {
    /// Endpoint object identity.
    public let id: ObjectID
    /// Payload representation fixed during registration.
    public let representation: IoValueRepresentation
    /// Recommendation encoded into the canonical object, including zero.
    public let recommendedUpdateRateMS: UInt32?
    private let objectBytes: BoundedIoBytes<512>

    /// Consumes actor metadata and derives its runtime-owned wire fields.
    ///
    /// - Parameters:
    ///   - metadata: Validated typed actor object to consume.
    ///   - representation: Representation fixed for the endpoint.
    ///   - recommendedUpdateRateMS: Optional recommendation, preserving zero.
    /// - Throws: ``ProtocolError`` when normalization or bounded copying fails.
    public init(
        metadata: consuming Object<IoActorMetadata>,
        representation: IoValueRepresentation,
        recommendedUpdateRateMS: UInt32?
    ) throws(ProtocolError) {
        var object = metadata
        do throws(ObjectError) {
            try object.edit { fields in
                fields.useRawIoValues = representation == .binary ? true : nil
                fields.updateRate = recommendedUpdateRateMS.map(UInt64.init)
                fields.externalRoute = nil
            }
        } catch {
            throw protocolError(error)
        }

        let snapshot = try endpointSnapshot(of: object)
        id = snapshot.id
        objectBytes = snapshot.bytes
        self.representation = representation
        self.recommendedUpdateRateMS = recommendedUpdateRateMS
    }

    /// Borrows the normalized canonical object bytes synchronously.
    ///
    /// - Parameter body: Nonescaping visitor for the canonical object.
    /// - Returns: The visitor result.
    /// - Throws: An error thrown by `body`.
    public borrowing func withObjectBytes<R>(
        _ body: (borrowing ByteSlice) throws -> R
    ) rethrows -> R {
        try objectBytes.withBytes(body)
    }
}

private func endpointSnapshot<Schema: ObjectSchema>(
    of object: borrowing Object<Schema>
) throws(ProtocolError) -> (id: ObjectID, bytes: BoundedIoBytes<512>) {
    var identifier: ObjectID?
    var snapshot: BoundedIoBytes<512>?
    object.withEncodedBytes { bytes in
        snapshot = try? BoundedIoBytes(copying: bytes)
        identifier = bytes.withBytes { pointer, length in
            let reader = WireReader(
                bytes: pointer.assumingMemoryBound(to: UInt8.self),
                length: length
            )
            return reader.readUUID("objectId").map(ObjectID.init(uuid:))
        }
    }
    guard let identifier, let snapshot else { throw ProtocolError(.malformedPayload) }
    return (identifier, snapshot)
}

private func protocolError(_ error: ObjectError) -> ProtocolError {
    switch error.reason {
    case .capacityExceeded, .fieldIndexOverflow:
        return ProtocolError(.capacityExceeded)
    default:
        return ProtocolError(.malformedPayload)
    }
}
