// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyObjectModel

import AxolotyWire

import Foundation

/// Fixed limits used by one host runtime instance.
public struct RuntimeCapacities: Sendable, Equatable {
    /// Maximum owned frames waiting for protocol processing.
    public let ingress: Int
    /// Maximum normalized actions retained for dispatch.
    public let dispatch: Int
    /// Maximum registered handlers.
    public let handlers: Int
    /// Maximum simultaneously supervised handler tasks.
    public let handlersInFlight: Int
    /// Maximum values retained by each public runtime stream.
    public let stream: Int
    /// Maximum event streams registered before startup.
    public let eventStreams: Int
    /// Maximum registered typed IO endpoints.
    public let ioEndpoints: Int
    /// Maximum retained latest IO values per source.
    public let ioPendingLatest: Int
    /// Maximum typed IO association observers.
    public let ioObservers: Int
    /// Maximum endpoint catalogue entries retained by the host definition.
    public let ioCatalogue: Int
    /// Largest protocol payload accepted by the shared processor.
    public let protocolMaximumPayloadBytes: Int
    /// Largest host profile topic accepted by the shared processor.
    public let protocolMaximumTopicBytes: Int
    /// Maximum active protocol objects accepted by the shared processor.
    public let protocolMaximumObjects: Int
    /// Maximum pending protocol correlations accepted by the shared processor.
    public let protocolMaximumPendingCorrelations: Int
    /// Coaty Core capabilities accepted by the shared processor.
    public let protocolCapabilities: ProtocolCapabilities

    /// Creates finite runtime limits.
    public init(
        ingress: Int = 64,
        dispatch: Int = 64,
        handlers: Int = 64,
        handlersInFlight: Int = 16,
        stream: Int = 64,
        eventStreams: Int = 64,
        ioEndpoints: Int = 64,
        ioPendingLatest: Int = 64,
        ioObservers: Int = 64,
        ioCatalogue: Int = 64,
        protocolMaximumPayloadBytes: Int = 512,
        protocolMaximumTopicBytes: Int = 512,
        protocolMaximumObjects: Int = 64,
        protocolMaximumPendingCorrelations: Int = 64,
        protocolCapabilities: ProtocolCapabilities = .coatyCore3
    ) throws {
        guard ingress > 0, dispatch > 0, handlers > 0,
              handlersInFlight > 0, stream > 0, eventStreams > 0,
              ioEndpoints > 0, ioPendingLatest > 0, ioObservers > 0,
              ioCatalogue > 0, protocolMaximumPayloadBytes > 0,
              protocolMaximumTopicBytes > 0,
              protocolMaximumObjects > 0, protocolMaximumPendingCorrelations > 0 else {
            throw AxolotyError.invalidArgument(
                argument: "capacities",
                reason: "all runtime capacities must be greater than zero"
            )
        }
        guard ingress <= 64, dispatch <= 64, handlers <= 64,
              handlersInFlight <= 64, stream <= 64, eventStreams <= 64,
              ioEndpoints <= 64, ioPendingLatest <= 64, ioObservers <= 64,
              ioCatalogue <= 64, protocolMaximumPayloadBytes <= 65_536,
              protocolMaximumTopicBytes <= 65_536,
              protocolMaximumObjects <= 64, protocolMaximumPendingCorrelations <= 64 else {
            throw AxolotyError.invalidArgument(
                argument: "capacities",
                reason: "host runtime capacities cannot exceed 64"
            )
        }
        self.ingress = ingress
        self.dispatch = dispatch
        self.handlers = handlers
        self.handlersInFlight = handlersInFlight
        self.stream = stream
        self.eventStreams = eventStreams
        self.ioEndpoints = ioEndpoints
        self.ioPendingLatest = ioPendingLatest
        self.ioObservers = ioObservers
        self.ioCatalogue = ioCatalogue
        self.protocolMaximumPayloadBytes = protocolMaximumPayloadBytes
        self.protocolMaximumTopicBytes = protocolMaximumTopicBytes
        self.protocolMaximumObjects = protocolMaximumObjects
        self.protocolMaximumPendingCorrelations = protocolMaximumPendingCorrelations
        self.protocolCapabilities = protocolCapabilities
    }
}

/// Stable identity supplied to a runtime before it starts.
public struct RuntimeIdentity: Sendable, Equatable {
    /// The protocol identity used in routing keys.
    public let id: UUID16
    /// A bounded human-readable name used by advertisements and diagnostics.
    public let name: String

    /// Creates a runtime identity.
    public init(id: UUID16, name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128 else {
            throw AxolotyError.invalidArgument(argument: "name", reason: "must contain 1 to 128 UTF-8 bytes")
        }
        self.id = id
        self.name = name
    }
}

/// Lifecycle state exposed by a runtime instance.
public enum RuntimeState: Sendable, Equatable {
    /// Configuration exists but transport has not started.
    case initialized
    /// Subscriptions and transport are being installed.
    case starting
    /// The runtime accepts protocol work.
    case running
    /// Transport is reconnecting and old requests are being resolved.
    case reconnecting
    /// Shutdown is draining bounded work.
    case stopping
    /// The instance stopped and cannot be started again.
    case stopped
    /// A terminal startup or transport failure occurred.
    case failed
}

enum RuntimeIoEndpointRole: Sendable, Equatable {
    case source
    case actor
}

struct RuntimeIoEndpointRegistration: Sendable {
    let id: ObjectID
    let role: RuntimeIoEndpointRole
    let representation: IoValueRepresentation
    let objectBytes: BoundedIoBytes<512>
    let publication: IoPublicationPolicy
    let recommendedUpdateRateMS: UInt32?
    let handler: (@Sendable ([UInt8], IoDeliveryContext) async throws -> Void)?
}

func runtimeRegistryNonce() -> ObjectID {
    let uuid = UUID().uuid
    return ObjectID(uuid: UUID16(bytes: (
        uuid.0, uuid.1, uuid.2, uuid.3,
        uuid.4, uuid.5, uuid.6, uuid.7,
        uuid.8, uuid.9, uuid.10, uuid.11,
        uuid.12, uuid.13, uuid.14, uuid.15
    )))
}

func runtimeObjectBytes(
    source definition: borrowing IoSourceEndpointDefinition
) throws(ProtocolError) -> BoundedIoBytes<512> {
    var result: BoundedIoBytes<512>?
    definition.withObjectBytes { bytes in result = try? BoundedIoBytes(copying: bytes) }
    guard let result else { throw ProtocolError(.capacityExceeded) }
    return result
}

func runtimeObjectBytes(
    actor definition: borrowing IoActorEndpointDefinition
) throws(ProtocolError) -> BoundedIoBytes<512> {
    var result: BoundedIoBytes<512>?
    definition.withObjectBytes { bytes in result = try? BoundedIoBytes(copying: bytes) }
    guard let result else { throw ProtocolError(.capacityExceeded) }
    return result
}
