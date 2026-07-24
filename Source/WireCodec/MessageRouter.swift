// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The common routing interface for both host and embedded runtimes.
///
/// The host runtime keeps its existing `Broadcast<Element>` actors for full
/// concurrency support. The embedded target uses `StaticDispatchTable` for
/// synchronous, allocation-free dispatch. Both implement this protocol so
/// routing code can be written once and compiled for either target.
///
/// - Note: Subscription interfaces differ between host (async streams) and
///   embedded (synchronous callbacks). This protocol covers only the dispatch
///   path, which is where the MQTT client hands an incoming message to the
///   routing layer. Each adapter provides its own subscribe/unsubscribe API.
public protocol MessageRouter: Sendable {
    /// Dispatches an incoming MQTT message to all matching subscribers.
    ///
    /// On the host, this converts the borrowed bytes to owned types
    /// (`ParsedMQTTMessage`) and sends them through the existing `Broadcast`
    /// actor infrastructure. On embedded, this dispatches directly to
    /// `StaticDispatchTable` callbacks with no allocation.
    func dispatch(_ message: BorrowedMessage)
}
