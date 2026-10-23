// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// One immutable lifecycle transition observed by a runtime.
public struct RuntimeLifecycleObservation: Sendable, Equatable {
    /// The state the runtime left.
    public let from: RuntimeLifecycleState
    /// The state the runtime entered.
    public let to: RuntimeLifecycleState
    /// The transport epoch active at the transition.
    public let transportEpoch: UInt64

    /// The state before the transition.
    public var previous: RuntimeLifecycleState { from }
    /// The state after the transition.
    public var current: RuntimeLifecycleState { to }

    /// Creates a lifecycle observation.
    public init(from: RuntimeLifecycleState, to: RuntimeLifecycleState, transportEpoch: UInt64) {
        self.from = from
        self.to = to
        self.transportEpoch = transportEpoch
    }
}

/// Why the runtime started a reconnect.
public enum RuntimeReconnectCause: String, Sendable, Equatable, CaseIterable {
    /// A caller requested the reconnect.
    case requested
    /// A transport failure or failed publication forced the reconnect.
    case transportFailure
}

/// One reconnect attempt with bounded, carrier-neutral evidence.
public struct RuntimeReconnectObservation: Sendable, Equatable {
    /// Why the attempt started.
    public let cause: RuntimeReconnectCause
    /// The cumulative reconnect count at the start of the attempt.
    public let attempt: UInt64
    /// The transport epoch installed by the attempt.
    public let transportEpoch: UInt64

    /// Creates a reconnect observation.
    public init(cause: RuntimeReconnectCause, attempt: UInt64, transportEpoch: UInt64) {
        self.cause = cause
        self.attempt = attempt
        self.transportEpoch = transportEpoch
    }
}

/// A bounded runtime resource whose admission could reject or discard work.
public enum RuntimeAdmissionResource: String, Sendable, Equatable, CaseIterable {
    /// The bounded transport ingress queue.
    case ingress
    /// The bounded dispatch or outbound-retention queue.
    case dispatch
    /// The bounded handler-supervision budget.
    case handlers
    /// A registered application event stream.
    case applicationEvents
}

/// How a bounded resource rejected or discarded one value.
public enum RuntimeAdmissionOutcome: String, Sendable, Equatable, CaseIterable {
    /// The work was rejected before it was accepted.
    case rejected
    /// The work was accepted earlier but could not be delivered.
    case dropped
}

/// Admission or saturation evidence for one bounded resource.
public struct RuntimeAdmissionObservation: Sendable, Equatable {
    /// The saturated resource.
    public let resource: RuntimeAdmissionResource
    /// Whether the work was rejected or dropped.
    public let outcome: RuntimeAdmissionOutcome
    /// The finite capacity that was exhausted.
    public let capacity: Int

    /// Creates an admission observation.
    public init(resource: RuntimeAdmissionResource, outcome: RuntimeAdmissionOutcome, capacity: Int) {
        self.resource = resource
        self.outcome = outcome
        self.capacity = capacity
    }
}

/// The terminal or intermediate outcome of one local request correlation.
public enum RuntimeRequestOutcome: String, Sendable, Equatable, CaseIterable {
    /// The processor accepted the request and recorded its correlation.
    case accepted
    /// The processor or runtime rejected the request.
    case rejected
    /// The request deadline expired.
    case expired
    /// The caller or a transport reset cancelled the request.
    case cancelled
    /// A correlated peer response reached the runtime.
    case responseReceived
}

/// Request outcome evidence without any payload bytes.
public struct RuntimeRequestObservation: Sendable, Equatable {
    /// The request or response family, when known.
    public let capability: ProtocolCapability?
    /// The request correlation, when known.
    public let correlationID: UUID16?
    /// The observed outcome.
    public let outcome: RuntimeRequestOutcome
    /// The structured rejection, when `outcome` indicates rejection.
    public let rejection: RuntimeRejection?

    /// Creates a request observation.
    public init(
        capability: ProtocolCapability?,
        correlationID: UUID16?,
        outcome: RuntimeRequestOutcome,
        rejection: RuntimeRejection? = nil
    ) {
        self.capability = capability
        self.correlationID = correlationID
        self.outcome = outcome
        self.rejection = rejection
    }
}

/// How the runtime learned that an object's presence changed.
public enum RuntimePresenceEvidence: String, Sendable, Equatable, CaseIterable {
    /// A local operation advertised an object.
    case localAdvertisement
    /// A peer advertisement reached the runtime.
    case peerAdvertisement
    /// A local operation deadvertised an object.
    case localDeadvertisement
    /// A peer deadvertisement reached the runtime.
    case peerDeadvertisement
    /// A transport reset invalidated peer presence.
    case transportReset
}

/// Presence evidence without any object payload.
public struct RuntimePresenceObservation: Sendable, Equatable {
    /// The source identity, when known.
    public let sourceID: UUID16?
    /// The advertised or deadvertised object identity, when known.
    public let objectID: UUID16?
    /// How the runtime learned about the change.
    public let evidence: RuntimePresenceEvidence
    /// Active object count after the change.
    public let activeObjects: Int
    /// The protocol processor generation after the change.
    public let generation: UInt32

    /// Creates a presence observation.
    public init(
        sourceID: UUID16?,
        objectID: UUID16?,
        evidence: RuntimePresenceEvidence,
        activeObjects: Int,
        generation: UInt32
    ) {
        self.sourceID = sourceID
        self.objectID = objectID
        self.evidence = evidence
        self.activeObjects = activeObjects
        self.generation = generation
    }
}

/// A transport failure with a typed code and bounded detail.
public struct RuntimeTransportObservation: Sendable, Equatable {
    /// The stable runtime error code.
    public let code: AxolotyError.RuntimeErrorCode
    /// A bounded human-readable detail.
    public let detail: String

    /// Creates a transport observation.
    public init(code: AxolotyError.RuntimeErrorCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// Carrier-neutral capability and capacity information for one runtime.
public struct RuntimeCapabilityInformation: Sendable, Equatable {
    /// Coaty capabilities accepted by the shared processor.
    public let protocolCapabilities: ProtocolCapabilities
    /// Optional features provided by the selected transport adapter.
    public let transportCapabilities: RuntimeTransportCapabilities
    /// The single wire profile used by the binding.
    public let wireProfile: WireProfile
    /// Largest protocol payload accepted by the shared processor.
    public let maximumPayloadBytes: Int
    /// Maximum active protocol objects accepted by the shared processor.
    public let maximumObjects: Int
    /// Maximum pending protocol correlations accepted by the shared processor.
    public let maximumPendingCorrelations: Int
    /// Minimum capacity of the diagnostic stream.
    public let diagnosticCapacity: Int

    /// Creates capability information.
    ///
    /// - Parameters:
    ///   - protocolCapabilities: Protocol families accepted by the processor.
    ///   - transportCapabilities: Optional features provided by the adapter.
    ///   - wireProfile: The single profile selected by the adapter.
    ///   - maximumPayloadBytes: Largest accepted protocol payload.
    ///   - maximumObjects: Maximum active protocol objects.
    ///   - maximumPendingCorrelations: Maximum pending request correlations.
    ///   - diagnosticCapacity: Capacity of the bounded diagnostic stream.
    public init(
        protocolCapabilities: ProtocolCapabilities,
        transportCapabilities: RuntimeTransportCapabilities = [],
        wireProfile: WireProfile,
        maximumPayloadBytes: Int,
        maximumObjects: Int,
        maximumPendingCorrelations: Int,
        diagnosticCapacity: Int
    ) {
        self.protocolCapabilities = protocolCapabilities
        self.transportCapabilities = transportCapabilities
        self.wireProfile = wireProfile
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumObjects = maximumObjects
        self.maximumPendingCorrelations = maximumPendingCorrelations
        self.diagnosticCapacity = diagnosticCapacity
    }
}

/// The typed value carried by one ``RuntimeDiagnostic``.
///
/// Every case owns its values. No case carries a borrowed buffer, raw route,
/// payload, or transport handle.
public enum RuntimeObservation: Sendable, Equatable {
    /// A runtime lifecycle transition.
    case lifecycle(RuntimeLifecycleObservation)
    /// A reconnect attempt.
    case reconnect(RuntimeReconnectObservation)
    /// Admission or saturation of a bounded resource.
    case admission(RuntimeAdmissionObservation)
    /// The outcome of one request correlation.
    case request(RuntimeRequestObservation)
    /// A change in observable object presence.
    case presence(RuntimePresenceObservation)
    /// A transport failure.
    case transportFailure(RuntimeTransportObservation)
    /// The capabilities and capacities supported by this runtime.
    case capabilities(RuntimeCapabilityInformation)
}
