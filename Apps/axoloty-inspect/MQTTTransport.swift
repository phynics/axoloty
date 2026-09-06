// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyInspectorCore
import AxolotyInspectorRuntime

/// Builds the MQTT transport this executable is built to speak.
///
/// Carrier selection lives in the composition root. `AxolotyInspectorRuntime`
/// and `AxolotyMCP` compose protocol behavior and name no transport, so a
/// second carrier is a change here rather than in either of them.
enum MQTTInspectorTransport {
    static let factory: AxolotyInspectorSession.TransportFactory = { configuration in
        try MQTTBinding(configuration: MQTTBindingConfiguration(
            host: configuration.host,
            port: configuration.port,
            usesTLS: configuration.usesTLS,
            username: configuration.username,
            password: configuration.password,
            connectionTimeoutMS: configuration.connectTimeoutMilliseconds
        ))
    }
}
