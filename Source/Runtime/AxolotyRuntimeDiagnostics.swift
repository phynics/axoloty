// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol

/// Coalesced supervision counters for a runtime instance.
public struct RuntimeDiagnostics: Sendable, Equatable {
    public var ingressSaturation = 0
    public var dispatchSaturation = 0
    public var handlerSaturation = 0
    public var reconnects = 0
    public var expiredRequests = 0
    public var malformedFrames = 0
    public var transportFailures = 0

    /// Creates an empty diagnostics snapshot.
    public init() {}
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
    }

    /// The diagnostic category.
    public let kind: Kind
    /// A bounded human-readable detail.
    public let detail: String

    /// Creates a diagnostic.
    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}
