// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

extension RuntimeDefinition.Builder {
    /// Registers a typed, fixed-representation IO source before startup.
    ///
    /// - Parameters:
    ///   - metadata: The consumed source object metadata.
    ///   - valueType: The portable value type used by the source.
    ///   - publication: The bounded publication policy.
    ///   - externalRoute: An optional validated exact MQTT route.
    /// - Returns: A sealed-definition source handle.
    /// - Throws: ``AxolotyError`` when metadata or capacity validation fails.
    public mutating func ioSource<Value: IoValue>(
        metadata: consuming Object<IoSourceMetadata>,
        as valueType: Value.Type,
        publication: IoPublicationPolicy = .immediate,
        externalRoute: MQTTExternalIoRoute? = nil
    ) throws -> IoSource<Value> {
        do {
            _ = valueType
            let normalized = try normalizeSource(
                metadata: metadata,
                representation: Value.representation,
                publication: publication,
                externalRoute: externalRoute
            )
            return try appendIoSource(normalized, representation: Value.representation, publication: publication)
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    /// Registers a dynamic IO source whose representation is fixed at registration.
    ///
    /// - Parameters:
    ///   - metadata: The consumed source object metadata.
    ///   - representation: The representation accepted by the endpoint.
    ///   - publication: The bounded publication policy.
    ///   - externalRoute: An optional validated exact MQTT route.
    /// - Returns: A dynamic source handle.
    /// - Throws: ``AxolotyError`` when metadata or capacity validation fails.
    public mutating func dynamicIoSource(
        metadata: consuming Object<IoSourceMetadata>,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy = .immediate,
        externalRoute: MQTTExternalIoRoute? = nil
    ) throws -> IoSource<DynamicIoValue> {
        do {
            let normalized = try normalizeSource(
                metadata: metadata,
                representation: representation,
                publication: publication,
                externalRoute: externalRoute
            )
            return try appendIoSource(normalized, representation: representation, publication: publication)
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    /// Registers a typed host IO actor with an asynchronous application handler.
    ///
    /// - Parameters:
    ///   - metadata: The consumed actor object metadata.
    ///   - valueType: The portable value type delivered to the handler.
    ///   - recommendedUpdateRateMS: Optional actor recommendation.
    ///   - handler: The bounded asynchronous delivery callback.
    /// - Returns: A sealed-definition actor handle.
    /// - Throws: ``AxolotyError`` when metadata or capacity validation fails.
    public mutating func ioActor<Value: IoValue>(
        metadata: consuming Object<IoActorMetadata>,
        as valueType: Value.Type,
        recommendedUpdateRateMS: UInt32? = nil,
        handler: @escaping @Sendable (Value, IoDeliveryContext) async throws -> Void
    ) throws -> IoActor<Value> {
        do {
            _ = valueType
            let normalized = try IoActorEndpointDefinition(
                metadata: metadata,
                representation: Value.representation,
                recommendedUpdateRateMS: recommendedUpdateRateMS
            )
            let wrapped: @Sendable ([UInt8], IoDeliveryContext) async throws -> Void = { bytes, context in
                let value: Value? = bytes.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return nil }
                    return try? Value.decodeIoPayload(
                        ByteSlice(bytes: base, length: buffer.count),
                        representation: Value.representation
                    )
                }
                guard let value else { throw IoValueError.invalidValue }
                try await handler(value, context)
            }
            return try appendIoActor(
                normalized,
                representation: Value.representation,
                handler: wrapped
            )
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    /// Registers a dynamic host IO actor with a fixed accepted representation.
    ///
    /// - Parameters:
    ///   - metadata: The consumed actor object metadata.
    ///   - representation: The representation delivered to the handler.
    ///   - recommendedUpdateRateMS: Optional actor recommendation.
    ///   - handler: The bounded asynchronous delivery callback.
    /// - Returns: A dynamic actor handle.
    /// - Throws: ``AxolotyError`` when metadata or capacity validation fails.
    public mutating func dynamicIoActor(
        metadata: consuming Object<IoActorMetadata>,
        representation: IoValueRepresentation,
        recommendedUpdateRateMS: UInt32? = nil,
        handler: @escaping @Sendable (DynamicIoValue, IoDeliveryContext) async throws -> Void
    ) throws -> IoActor<DynamicIoValue> {
        do {
            let normalized = try IoActorEndpointDefinition(
                metadata: metadata,
                representation: representation,
                recommendedUpdateRateMS: recommendedUpdateRateMS
            )
            let wrapped: @Sendable ([UInt8], IoDeliveryContext) async throws -> Void = { bytes, context in
                let value: DynamicIoValue? = bytes.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return nil }
                    return try? DynamicIoValue.decodeIoPayload(
                        ByteSlice(bytes: base, length: buffer.count),
                        representation: representation
                    )
                }
                guard let value else { throw IoValueError.invalidValue }
                try await handler(value, context)
            }
            return try appendIoActor(normalized, representation: representation, handler: wrapped)
        } catch {
            throw AxolotyError.caught(error)
        }
    }

    private mutating func appendIoSource<Value: IoEndpointValue>(
        _ normalized: consuming IoSourceEndpointDefinition,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy
    ) throws(ProtocolError) -> IoSource<Value> {
        guard !definition.sealed,
              definition.ioEndpointRegistrations.count < definition.endpointRegistrationLimit else {
            throw ProtocolError(.capacityExceeded)
        }
        guard !definition.ioEndpointRegistrations.contains(where: { $0.id == normalized.id }) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let bytes = try runtimeObjectBytes(source: normalized)
        let slot = definition.ioEndpointRegistrations.count
        definition.ioEndpointRegistrations.append(RuntimeIoEndpointRegistration(
            id: normalized.id,
            role: .source,
            representation: representation,
            objectBytes: bytes,
            publication: publication,
            recommendedUpdateRateMS: nil,
            handler: nil
        ))
        return IoSource(
            registryID: definition.registryID,
            slot: UInt16(slot),
            generation: 1,
            id: normalized.id,
            representation: representation
        )
    }

    private func normalizeSource(
        metadata: consuming Object<IoSourceMetadata>,
        representation: IoValueRepresentation,
        publication: IoPublicationPolicy,
        externalRoute: MQTTExternalIoRoute?
    ) throws(ProtocolError) -> IoSourceEndpointDefinition {
        guard let externalRoute else {
            return try IoSourceEndpointDefinition(
                metadata: metadata,
                representation: representation,
                publication: publication
            )
        }
        guard !externalRoute.topic.hasPrefix("coaty/3/") else {
            throw ProtocolError(.externalRouteMismatch)
        }
        return try IoSourceEndpointDefinition(
            metadata: metadata,
            representation: representation,
            publication: publication,
            externalRoute: externalRoute.topicBytes
        )
    }

    private mutating func appendIoActor<Value: IoEndpointValue>(
        _ normalized: consuming IoActorEndpointDefinition,
        representation: IoValueRepresentation,
        handler: @escaping @Sendable ([UInt8], IoDeliveryContext) async throws -> Void
    ) throws(ProtocolError) -> IoActor<Value> {
        guard !definition.sealed,
              definition.ioEndpointRegistrations.count < definition.endpointRegistrationLimit else {
            throw ProtocolError(.capacityExceeded)
        }
        guard !definition.ioEndpointRegistrations.contains(where: { $0.id == normalized.id }) else {
            throw ProtocolError(.invalidEndpoint)
        }
        let bytes = try runtimeObjectBytes(actor: normalized)
        let slot = definition.ioEndpointRegistrations.count
        definition.ioEndpointRegistrations.append(RuntimeIoEndpointRegistration(
            id: normalized.id,
            role: .actor,
            representation: representation,
            objectBytes: bytes,
            publication: .immediate,
            recommendedUpdateRateMS: normalized.recommendedUpdateRateMS,
            handler: handler
        ))
        return IoActor(
            registryID: definition.registryID,
            slot: UInt16(slot),
            generation: 1,
            id: normalized.id,
            representation: representation
        )
    }
}
