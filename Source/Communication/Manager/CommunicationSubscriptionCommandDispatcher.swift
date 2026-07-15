// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Serializes subscription commands before forwarding them to a communication
/// client.
actor CommunicationSubscriptionCommandDispatcher {

    private let client: CommunicationClient

    init(client: CommunicationClient) {
        self.client = client
    }

    func deliver(_ command: SubscriptionCommand) async throws {
        switch command {
        case .subscribe(let topic):
            try await client.subscribe(topic)
        case .unsubscribe(let topic):
            try await client.unsubscribe(topic)
        }
    }
}
