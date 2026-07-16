// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Observes parsed transport messages for manager-owned protocol plumbing.
    internal func observeParsedMessages() async -> EventStream<ParsedMQTTMessage> {
        await eventHub.registerStream(
            key: CommunicationEventHubKeys.parsedMQTTMessage,
            buffering: .event,
            onFirst: {},
            onLast: {}
        )
    }

    /// Starts the internal Associate-event consumer for each configured IO node.
    internal func _observeAssociate() {
        for ioNode in ioNodes {
            let task = _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                let topic = CommunicationTopic.createTopicStringByLevelsForSubscribe(
                    eventType: .Associate,
                    eventTypeFilter: ioNode.name,
                    namespace: communicationOptions.shouldEnableCrossNamespacing ? nil : namespace,
                    correlationId: nil
                )
                await self.subscriptionCoordinator?.acquire(topic: topic)
                let stream = await self.observeParsedMessages()
                for await parsed in stream {
                    guard parsed.eventType == .Associate,
                          parsed.eventTypeFilter == ioNode.name,
                          let payload: AssociateEvent = PayloadCoder.decode(parsed.payload) else { continue }
                    payload.type = .Associate
                    if let sourceId = CoatyUUID(uuidString: parsed.sourceId) { payload.sourceId = sourceId }
                    self.handleAssociate(event: payload)
                }
            }
            lifecycleTasks.append(task)
        }
    }

    /// Subscribes to the Discover stream and resolves matching objects.
    ///
    /// `predicate` decides whether an incoming Discover event should be answered;
    /// `resolve` publishes the Resolve response(s) for a matching event, using the
    /// supplied correlation ID. Both closures receive the manager so they need not
    /// capture `self`.
    internal func respondToDiscover(
        matching predicate: @escaping @MainActor @Sendable (CommunicationManager, DiscoverEventSnapshot) -> Bool,
        resolve: @escaping @MainActor @Sendable (CommunicationManager, DiscoverEventSnapshot, String) -> Void
    ) {
        let task = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.observeDiscoverStream()
            for await event in stream {
                guard predicate(self, event), let correlationId = event.correlationId else { continue }
                resolve(self, event, correlationId)
            }
        }
        lifecycleTasks.append(task)
    }

    /// Starts the internal Discover-event consumer that resolves configured IO nodes.
    internal func observeDiscoverIoNodes() {
        guard !ioNodes.isEmpty else { return }
        respondToDiscover(
            matching: { _, event in event.coreTypes?.contains(.IoNode) == true },
            resolve: { manager, _, correlationId in
                for node in manager.ioNodes {
                    manager.publishResolve(event: ResolveEvent.with(object: node), correlationId: correlationId)
                }
            }
        )
    }
}
