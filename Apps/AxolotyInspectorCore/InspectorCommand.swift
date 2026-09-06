// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The top-level inspector command selected by the operator.
///
/// During Phase A only ``InspectorCommand/catalog(_:)`` is implemented;
/// parsing ``discover`` returns an unsupported-command error.
public enum InspectorCommand: Equatable, Sendable {
    /// Passive observation of Advertise and Deadvertise events.
    case catalog(CatalogCommand)
    /// Active discovery via a single Discover request and Resolve collection.
    case discover(DiscoverCommand)
}

/// Options for the passive catalogue command.
public struct CatalogCommand: Equatable, Sendable {
    /// The observation duration. ``InspectorDuration/unlimited`` runs until
    /// interrupted.
    public let duration: InspectorDuration
    /// Filter by Coaty core type (e.g. ``"Identity"``, ``"Sensor"``).
    public let coreType: String?
    /// Filter by full object type string.
    public let objectType: String?
    /// Filter by object UUID.
    public let objectId: String?
    /// Filter by source (advertiser) UUID.
    public let sourceId: String?
    /// Include the complete raw object JSON payload in output.
    public let full: Bool
    /// Include private data in output. Requires ``full`` to take effect.
    public let includePrivateData: Bool

    /// Creates catalogue command options.
    public init(
        duration: InspectorDuration = .unlimited,
        coreType: String? = nil,
        objectType: String? = nil,
        objectId: String? = nil,
        sourceId: String? = nil,
        full: Bool = false,
        includePrivateData: Bool = false
    ) {
        self.duration = duration
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.sourceId = sourceId
        self.full = full
        self.includePrivateData = includePrivateData
    }
}

/// Options for the active discovery command.
public struct DiscoverCommand: Equatable, Sendable {
    /// Filter by Coaty core type.
    public let coreType: String?
    /// Filter by full object type string.
    public let objectType: String?
    /// Filter by object UUID.
    public let objectId: String?
    /// The response collection timeout.
    public let timeout: InspectorDuration

    /// Creates discovery command options.
    public init(
        coreType: String? = nil,
        objectType: String? = nil,
        objectId: String? = nil,
        timeout: InspectorDuration = .unlimited
    ) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.timeout = timeout
    }
}
