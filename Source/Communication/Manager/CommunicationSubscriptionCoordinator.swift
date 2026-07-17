// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A command emitted by ``CommunicationSubscriptionCoordinator`` to subscribe or
/// unsubscribe a single topic on the underlying communication client.
public enum SubscriptionCommand: Sendable, Equatable {
    /// Subscribe to the given topic.
    case subscribe(String)
    /// Unsubscribe from the given topic.
    case unsubscribe(String)
}

/// Coordinates topic subscription lifetimes and translates them into idempotent
/// subscribe and unsubscribe commands for a communication client.
///
/// The coordinator owns the desired topic reference counts, the online/offline
/// state, and the active subscription state. It emits exactly one subscribe
/// command the first time a desired topic becomes active, and exactly one
/// unsubscribe command when the final reference to an active topic is released.
/// While offline, new acquisitions are recorded but no commands are emitted.
/// When the coordinator transitions from offline to online, every currently
/// desired topic is subscribed exactly once. When transitioning from online to
/// offline, desired topics are retained and no unsubscriptions are emitted.
public actor CommunicationSubscriptionCoordinator {

    /// Reference counts for topics that are currently desired.
    private var desiredCounts: [String: Int] = [:]

    /// Topics for which a subscribe command has been emitted and not yet
    /// matched by an unsubscribe command.
    private var activeTopics: Set<String> = []

    /// Whether the coordinator is currently online.
    private var isOnline: Bool = false

    /// A sink that receives subscribe and unsubscribe commands produced by the
    /// coordinator.
    private let commandSink: @Sendable (SubscriptionCommand) async throws -> Void
    private var lastCommandError: AxolotyError?

    /// Creates a new coordinator with the given command sink.
    ///
    /// - Parameter commandSink: A closure that is invoked whenever the
    ///   coordinator produces a ``SubscriptionCommand``. The closure is called
    ///   on the actor's isolation context.
    public init(commandSink: @Sendable @escaping (SubscriptionCommand) async -> Void) {
        self.commandSink = { command in
            await commandSink(command)
        }
    }

    /// Creates a coordinator with a command sink that can report transport
    /// failures.
    ///
    /// - Parameter throwingCommandSink: A command sink that may fail when the
    ///   underlying transport rejects a subscription operation.
    internal init(
        throwingCommandSink: @Sendable @escaping (SubscriptionCommand) async throws -> Void
    ) {
        self.commandSink = throwingCommandSink
    }

    /// Increments the desired subscription count for the given topic.
    ///
    /// If the coordinator is online and the topic is not yet active, a single
    /// `.subscribe` command is emitted. Subsequent acquisitions while the topic
    /// is already active do not produce additional commands.
    ///
    /// - Parameter topic: The topic to acquire.
    public func acquire(topic: String) async {
        desiredCounts[topic, default: 0] += 1

        guard isOnline, !activeTopics.contains(topic) else {
            return
        }

        activeTopics.insert(topic)
        do {
            try await commandSink(.subscribe(topic))
        } catch {
            activeTopics.remove(topic)
            lastCommandError = .caught(error)
        }
    }

    /// Decrements the desired subscription count for the given topic.
    ///
    /// When the count reaches zero and the topic is active, a single
    /// `.unsubscribe` command is emitted and the topic is removed from the
    /// active set. Releasing a topic that is not desired is ignored.
    ///
    /// - Parameter topic: The topic to release.
    public func release(topic: String) async {
        guard let count = desiredCounts[topic], count > 0 else {
            return
        }

        if count == 1 {
            desiredCounts.removeValue(forKey: topic)
            if activeTopics.remove(topic) != nil {
                do {
                    try await commandSink(.unsubscribe(topic))
                } catch {
                    lastCommandError = .caught(error)
                }
            }
        } else {
            desiredCounts[topic] = count - 1
        }
    }

    /// Sets the online state of the coordinator.
    ///
    /// When transitioning to online, every currently desired topic is subscribed
    /// exactly once. When transitioning to offline, desired topics are retained
    /// but no unsubscriptions are emitted; the active set is cleared because the
    /// physical subscriptions are no longer considered active.
    ///
    /// - Parameter online: `true` when the communication client is connected,
    ///   `false` otherwise.
    public func setOnline(_ online: Bool) async {
        guard isOnline != online else {
            return
        }

        isOnline = online

        if online {
            let topicsToActivate = desiredCounts.keys.filter { !activeTopics.contains($0) }.sorted()
            for topic in topicsToActivate {
                do {
                    try await commandSink(.subscribe(topic))
                    activeTopics.insert(topic)
                } catch {
                    lastCommandError = .caught(error)
                }
            }
        } else {
            activeTopics.removeAll()
        }
    }

    /// Clears all desired subscriptions and emits unsubscriptions for topics
    /// that are currently active.
    ///
    /// After reset, the coordinator is in the same state as after initialization,
    /// regardless of the current online state.
    public func reset() async {
        if isOnline {
            for topic in activeTopics.sorted() {
                do {
                    try await commandSink(.unsubscribe(topic))
                } catch {
                    lastCommandError = .caught(error)
                }
            }
        }

        desiredCounts.removeAll()
        activeTopics.removeAll()
        isOnline = false
    }

    /// Retries activation for desired topics that are not currently active.
    internal func activateDesiredTopics() async {
        guard isOnline else {
            return
        }

        let topicsToActivate = desiredCounts.keys
            .filter { !activeTopics.contains($0) }
            .sorted()
        for topic in topicsToActivate {
            do {
                try await commandSink(.subscribe(topic))
                activeTopics.insert(topic)
            } catch {
                lastCommandError = .caught(error)
            }
        }
    }

    /// Returns and clears the most recent command delivery failure.
    internal func takeCommandError() -> AxolotyError? {
        defer { lastCommandError = nil }
        return lastCommandError
    }
}
