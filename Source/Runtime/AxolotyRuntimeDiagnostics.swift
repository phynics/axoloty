// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

import AxolotyWire

/// Coalesced supervision counters for a runtime instance.
public struct RuntimeDiagnostics: Sendable, Equatable {
    public var ingressSaturation = 0
    public var dispatchSaturation = 0
    public var handlerSaturation = 0
    public var reconnects = 0
    public var expiredRequests = 0
    public var malformedFrames = 0
    public var transportFailures = 0
    /// Transport frames admitted to the runtime receive callback.
    public var receivedFrames: UInt64 = 0
    /// Successful outbound transport publications.
    public var publishedFrames: UInt64 = 0
    /// Inbound transport samples discarded before the runtime callback.
    public var receiveDrops: UInt64 = 0
    /// Inbound transport samples rejected because route or payload capacity was exceeded.
    public var oversizedSamples: UInt64 = 0
    /// Successful transport-session opens.
    public var sessionOpens: UInt64 = 0
    /// Failed session opens or failures reported by an open session.
    public var sessionFailures: UInt64 = 0
    /// Successful transport-session opens after the first successful open.
    public var transportReconnects: UInt64 = 0
    /// Current number of distinct active external subscriptions.
    public var activeExternalSubscriptions: UInt64 = 0

    /// Values offered to the bounded diagnostic stream.
    public var diagnosticsEmitted: UInt64 = 0
    /// Diagnostic values lost because the bounded stream was full.
    public var diagnosticsDropped: UInt64 = 0
    /// The sequence number of the most recently emitted diagnostic.
    public var diagnosticSequence: UInt64 = 0
    /// Minimum capacity of the diagnostic stream.
    public var diagnosticCapacity: Int = 0

    /// The latest runtime lifecycle transition.
    public var lifecycle = RuntimeLifecycleObservation(
        from: .stopped,
        to: .stopped,
        transportEpoch: 0
    )
    /// The latest reconnect attempt, or `nil` before the first attempt.
    public var lastReconnect: RuntimeReconnectObservation?

    /// Active objects retained by the shared protocol processor.
    public var activeObjects: Int = 0
    /// The protocol processor generation at the last presence observation.
    public var presenceGeneration: UInt32 = 0
    /// Whether a transport reset made peer presence non-authoritative.
    public var presenceUncertain = false
    /// Number of transport resets that invalidated peer presence.
    public var presenceResets: UInt64 = 0
    /// Number of presence changes observed without payload bytes.
    public var presenceChanges: UInt64 = 0
    /// The latest presence observation, or `nil` before the first change.
    public var lastPresence: RuntimePresenceObservation?

    /// Requests accepted by the shared processor.
    public var acceptedRequests: UInt64 = 0
    /// Requests rejected before the processor accepted them.
    public var rejectedRequests: UInt64 = 0
    /// Requests cancelled locally or by a transport reset.
    public var cancelledRequests: UInt64 = 0
    /// Correlated responses delivered to the runtime.
    public var responsesReceived: UInt64 = 0
    /// Requests still awaiting a response.
    public var pendingRequests: Int = 0

    /// Supported capabilities and finite capacities.
    public var capabilities = RuntimeCapabilityInformation(
        protocolCapabilities: .coatyCore3,
        transportCapabilities: [],
        wireProfile: .coaty3JSON,
        maximumPayloadBytes: 0,
        maximumObjects: 0,
        maximumPendingCorrelations: 0,
        diagnosticCapacity: 0
    )

    /// The current lifecycle state.
    public var lifecycleState: RuntimeLifecycleState { lifecycle.to }
    /// The binding's single wire profile.
    public var wireProfile: WireProfile { capabilities.wireProfile }
    /// Coaty capabilities accepted by the shared processor.
    public var protocolCapabilities: ProtocolCapabilities { capabilities.protocolCapabilities }
    /// Grouped request outcomes.
    public var requestOutcomes: RuntimeRequestOutcomes {
        RuntimeRequestOutcomes(
            accepted: acceptedRequests,
            rejected: rejectedRequests,
            expired: UInt64(max(0, expiredRequests)),
            cancelled: cancelledRequests,
            responses: responsesReceived
        )
    }

    /// Creates an empty diagnostics snapshot.
    public init() {}
}

/// Grouped request correlation outcomes from one diagnostics snapshot.
public struct RuntimeRequestOutcomes: Sendable, Equatable {
    /// Requests accepted by the processor.
    public var accepted: UInt64 = 0
    /// Requests rejected before acceptance.
    public var rejected: UInt64 = 0
    /// Requests whose deadline expired.
    public var expired: UInt64 = 0
    /// Requests cancelled locally or by a transport reset.
    public var cancelled: UInt64 = 0
    /// Correlated responses delivered to the runtime.
    public var responses: UInt64 = 0

    /// Creates grouped request outcomes.
    public init(
        accepted: UInt64 = 0,
        rejected: UInt64 = 0,
        expired: UInt64 = 0,
        cancelled: UInt64 = 0,
        responses: UInt64 = 0
    ) {
        self.accepted = accepted
        self.rejected = rejected
        self.expired = expired
        self.cancelled = cancelled
        self.responses = responses
    }
}

/// The externally visible lifecycle of a host runtime instance.
public enum RuntimeLifecycleState: UInt8, Sendable, Equatable {
    /// The runtime is not connected and may be started.
    case stopped
    /// The transport is being opened.
    case starting
    /// The transport and protocol executor are accepting work.
    case running
    /// The transport epoch is being replaced.
    case reconnecting
    /// The transport is being closed.
    case stopping
    /// Startup or transport initialization failed.
    case failed
    /// The runtime can no longer be started.
    case closed
}

/// A structured reason for a rejected runtime transition.
public enum RuntimeRejection: Sendable, Equatable {
    /// The runtime is not accepting work in its current lifecycle state.
    case notRunning(RuntimeLifecycleState)
    /// The inbound topic is empty or malformed.
    case malformedFrame(ProtocolError.Code)
    /// The operation payload is empty or invalid for its family.
    case malformedPayload
    /// A filtered Call operation name cannot be represented as one route segment.
    case invalidOperationName
    /// A processor-defined rejection code.
    case `protocol`(ProtocolError.Code)
    /// The finite runtime storage is saturated.
    case capacityExceeded
    /// A transport callback belongs to an earlier start epoch.
    case staleTransport
}

/// A bounded diagnostic emitted by the runtime supervision layer.
public struct RuntimeDiagnostic: Sendable, Equatable {
    /// Stable diagnostic category.
    ///
    /// - Note: ``RuntimeDiagnostic`` is public API; downstream code may
    ///   switch on or filter by this kind (e.g. alerting on
    ///   ``capacityExceeded``), so treat it as a semver surface -- add new
    ///   cases rather than repurposing or removing existing ones.
    public enum Kind: String, Sendable {
        /// A bounded queue could not accept more work.
        case capacityExceeded
        /// A handler task returned an error.
        case handlerFailed
        /// A transport operation failed.
        case transportFailed
        /// An inbound frame could not be parsed or validated.
        case malformedFrame
        /// A component payload was malformed or had the wrong type.
        case malformedPayload
        /// An inbound frame arrived from a transport epoch superseded by a
        /// later reconnect, and was discarded rather than processed. This is
        /// routine during reconnection, not a sign of queue saturation.
        case staleTransportFrame
        /// A reconnect attempt completed successfully.
        case reconnected
        /// A local request was accepted for correlation tracking.
        case requestAccepted
        /// A local request was rejected.
        case requestRejected
        /// A request deadline expired.
        case requestExpired
        /// A request was cancelled locally or by a transport reset.
        case requestCancelled
        /// A correlated peer response reached the runtime.
        case responseReceived
        /// Observable object presence changed.
        case presenceChanged
    }

    /// The diagnostic category.
    public let kind: Kind
    /// A bounded human-readable detail.
    public let detail: String
    /// A monotonic sequence number assigned by the runtime.
    ///
    /// A consumer that sees a jump can report bounded-stream loss without
    /// relying on the producer to retain a second history.
    public let sequence: UInt64
    /// The monotonic runtime time at which the value was emitted.
    public let timestampMS: UInt32
    /// The typed, owned observation carried by this diagnostic.
    public let observation: RuntimeObservation?

    /// Creates a diagnostic without a runtime-assigned sequence or observation.
    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
        self.sequence = 0
        self.timestampMS = 0
        self.observation = nil
    }

    /// Creates a typed diagnostic.
    public init(
        kind: Kind,
        detail: String,
        sequence: UInt64,
        timestampMS: UInt32,
        observation: RuntimeObservation? = nil
    ) {
        self.kind = kind
        self.detail = detail
        self.sequence = sequence
        self.timestampMS = timestampMS
        self.observation = observation
    }
}
