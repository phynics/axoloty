//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CommunicationClient.swift
//  Axoloty
//
//

import Foundation

/// Receives synchronous transport callbacks from a communication client.
///
/// The callbacks are delivered on the client's transport callback context and
/// are converted into manager-owned streams at the boundary. Implementations
/// must keep callback work short and non-blocking.
protocol CommunicationClientDelegate: Startable {
    func didUpdateCommunicationState(_ state: CommunicationState)
    func didReceiveRawMQTTMessage(topic: String, payload: [UInt8])
    func didReceiveIoValue(topic: String, payload: [UInt8])
    func didReceiveMessage(topic: CommunicationTopic, payload: String)
}

extension CommunicationClientDelegate {
    func didUpdateCommunicationState(_ state: CommunicationState) {}
    func didReceiveRawMQTTMessage(topic: String, payload: [UInt8]) {}
    func didReceiveIoValue(topic: String, payload: [UInt8]) {}
    func didReceiveMessage(topic: CommunicationTopic, payload: String) {}
}

/// This protocol defines the networking API of a communication client, such as
/// the `MQTTNIOClient` class.
///
/// Note: We expect our clients to use publish-subscribe communication.
protocol CommunicationClient: Sendable {

    /// Delegate necessary to start the communication manager
    /// when discovering the broker over mDNS.
    var delegate: Startable { get set }

    /// Async event hub that mirrors transport-level state and raw MQTT messages.
    var eventHub: EventHub { get }

    // MARK: - Connection methods.
    
    func connect(lastWillTopic: String, lastWillMessage: String)
    func disconnect()

    // MARK: - Pub-Sub methods.

    func publish(_ topic: String, message: String)
    func publish(_ topic: String, message: [UInt8])
    func subscribe(_ topic: String) async throws
    func unsubscribe(_ topic: String) async throws
}
