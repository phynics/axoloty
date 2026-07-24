// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The common routing interface for the embedded runtime.
///
/// The embedded target uses `StaticDispatchTable` for synchronous,
/// allocation-free dispatch. The host runtime routes directly through
/// `MQTTNIOClient.handlePublish` and does not implement this protocol.
///
/// - Note: Subscription interfaces differ between host (async streams) and
///   embedded (synchronous callbacks). This protocol covers only the dispatch
///   path. The embedded adapter provides its own subscribe/unsubscribe API.
public protocol MessageRouter: Sendable {
    /// Dispatches an incoming MQTT message to all matching subscribers.
    ///
    /// On the host, this converts the borrowed bytes to owned types
    /// (`ParsedMQTTMessage`) and sends them through the existing `Broadcast`
    /// actor infrastructure. On embedded, this dispatches directly to
    /// `StaticDispatchTable` callbacks with no allocation.
    func dispatch(_ message: BorrowedMessage)
}
