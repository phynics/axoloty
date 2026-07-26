// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The routing interface for the embedded runtime's synchronous dispatch path.
///
/// The embedded target uses `StaticDispatchTable` for synchronous,
/// allocation-free dispatch. The host runtime routes directly through
/// `MQTTNIOClient.handlePublish` and does not conform to this protocol.
///
/// This protocol is intentionally non-`Sendable`: conforming routers own
/// mutable dispatch tables that are safe to touch only from a single
/// execution context. Callers must invoke ``dispatch(_:)`` from the same
/// thread/isolation domain that owns the router; this type carries no
/// internal synchronization and is not safe to share across concurrency
/// boundaries.
///
/// - Note: Subscription interfaces differ between host (async streams) and
///   embedded (synchronous callbacks). This protocol covers only the
///   synchronous dispatch path. The embedded adapter provides its own
///   subscribe/unsubscribe API, also bound to the same single execution
///   context.
public protocol MessageRouter {
    /// Dispatches an incoming MQTT message to all matching subscribers.
    ///
    /// On embedded, this dispatches directly to `StaticDispatchTable`
    /// callbacks with no allocation. The host runtime does not implement
    /// this protocol; it routes through `MQTTNIOClient.handlePublish` and the
    /// existing `Broadcast` actor infrastructure instead.
    ///
    /// `BorrowedMessage` and any values derived from it are valid only for
    /// the synchronous duration of this call. Implementations and handlers
    /// must copy data before crossing an `await` or any isolation-domain
    /// boundary. Dispatch is synchronous and must be called from the single
    /// execution context that owns the router.
    func dispatch(_ message: BorrowedMessage)
}
