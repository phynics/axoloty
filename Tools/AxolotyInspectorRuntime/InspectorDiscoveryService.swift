// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// A request for active object discovery.
public struct InspectorDiscoveryRequest: Sendable, Equatable {
    /// Filter by core type name, if specified.
    public let coreType: String?
    /// Filter by full object type, if specified.
    public let objectType: String?
    /// Filter by object UUID, if specified.
    public let objectId: String?
    /// Maximum time to wait for responses, in milliseconds.
    public let timeoutMilliseconds: Int

    /// Creates a discovery request.
    public init(coreType: String? = nil, objectType: String? = nil, objectId: String? = nil, timeoutMilliseconds: Int = 5000) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// Whether at least one selector is provided.
    public var hasSelector: Bool {
        coreType != nil || objectType != nil || objectId != nil
    }
}

/// The result of an active discovery operation.
public struct InspectorDiscoveryResult: Sendable, Equatable {
    /// Whether the discovery timed out before all expected responses arrived.
    public let timedOut: Bool
    /// The discovered objects, deduplicated by object ID.
    public let objects: [InspectorObject]

    /// Creates a discovery result.
    public init(timedOut: Bool, objects: [InspectorObject]) {
        self.timedOut = timedOut
        self.objects = objects
    }
}

/// Protocol for performing active discovery.
public protocol InspectorDiscovering: Sendable {
    /// Performs discovery for the objects matching the given request.
    ///
    /// - Parameter request: The discovery selectors and timeout.
    /// - Returns: The discovery result, including any matched objects and
    ///   whether the operation timed out.
    func discover(request: InspectorDiscoveryRequest) async throws -> InspectorDiscoveryResult
}
