// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation
import Testing

// MARK: - Serve subcommand tests

@Test(arguments: ["mqtt", "mcp", "dev"])
func serveSubcommandHelpIsParsedWithoutStartingService(subcommand: String) {
    let result = AxolotyServeParser().parse(arguments: [subcommand, "--help"], environment: [:])
    let expectedTopic: AxolotyServeHelpTopic = switch subcommand {
    case "mqtt": .mqtt
    case "mcp": .mcp
    default: .dev
    }

    guard case .success(.help(let helpTopic)) = result else {
        Issue.record("expected help request, got \(result)")
        return
    }

    #expect(helpTopic == expectedTopic)
}

@Test
func serveMqttDefaultsToLoopback1883() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt"], environment: [:])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected mqtt success, got \(result)")
        return
    }
    #expect(config.listenHost == "127.0.0.1")
    #expect(config.port == 1883)
    #expect(config.logLevel == .info)
    #expect(config.output == .human)
}

@Test
func serveMqttAcceptsPortOverride() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "8883"], environment: [:])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.port == 8883)
}

@Test
func serveMqttAcceptsListenHostZeroForContainer() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--listen-host", "0.0.0.0"], environment: [:])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.listenHost == "0.0.0.0")
}

@Test
func serveMqttRejectsPortZero() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "0"], environment: [:])
    guard case .failure(.invalidPort("0")) = result else {
        Issue.record("expected invalidPort error, got \(result)")
        return
    }
}

@Test
func serveMqttRejectsNonNumericPort() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "abc"], environment: [:])
    guard case .failure(.invalidPort("abc")) = result else {
        Issue.record("expected invalidPort error")
        return
    }
}

@Test
func serveMqttRejectsOutOfRangePort() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "99999"], environment: [:])
    if case .failure(let err) = result {
        #expect(err == .invalidPort("99999"))
    } else {
        Issue.record("expected failure")
    }
}

@Test
func serveMqttRejectsInvalidOutputMode() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--output", "xml"], environment: [:])
    guard case .failure(.invalidOutputMode("xml")) = result else {
        Issue.record("expected invalidOutputMode")
        return
    }
}

@Test
func serveMqttAcceptsLogLevelDebug() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--log-level", "debug"], environment: [:])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.logLevel == .debug)
}

@Test
func serveMqttRejectsInvalidLogLevel() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--log-level", "trace"], environment: [:])
    guard case .failure(.invalidLogLevel("trace")) = result else {
        Issue.record("expected invalidLogLevel")
        return
    }
}

@Test
func serveMqttRejectsUnknownOption() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--tls"], environment: [:])
    guard case .failure(.unknownOption("tls")) = result else {
        Issue.record("expected unknownOption")
        return
    }
}

@Test
func serveMqttRejectsDuplicatePort() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "1883", "--port", "1884"], environment: [:])
    guard case .failure(.duplicateOption("port")) = result else {
        Issue.record("expected duplicateOption")
        return
    }
}

@Test
func serveMqttAcceptsEqualsSyntax() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port=8883"], environment: [:])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.port == 8883)
}

@Test
func serveMqttRejectsMissingValue() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port"], environment: [:])
    guard case .failure(.missingValue("port")) = result else {
        Issue.record("expected missingValue")
        return
    }
}

// MARK: - MCP stdio tests

@Test
func serveMcpStdioDefaults() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "stdio"], environment: [:])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.transport == .stdio)
    #expect(config.brokerHost == "localhost")
    #expect(config.brokerPort == 1883)
    #expect(config.namespace == "-")
    #expect(config.connectTimeout == "10s")
}

@Test
func serveMcpRequiresTransport() {
    let result = AxolotyServeParser().parse(arguments: ["mcp"], environment: [:])
    guard case .failure(.missingTransport) = result else {
        Issue.record("expected missingTransport")
        return
    }
}

@Test
func serveMcpRejectsInvalidConnectTimeout() {
    let result = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "stdio", "--connect-timeout", "0s"],
        environment: [:]
    )
    guard case .failure(.invalidDuration("0s")) = result else {
        Issue.record("expected invalidDuration")
        return
    }
}

@Test
func serveMcpAcceptsBoundedConnectTimeout() {
    let result = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "stdio", "--connect-timeout", "2m"],
        environment: [:]
    )
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.connectTimeout == "2m")
}

@Test
func serveMcpRejectsInvalidTransport() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "ws"], environment: [:])
    guard case .failure(.invalidTransport("ws")) = result else {
        Issue.record("expected invalidTransport")
        return
    }
}

@Test
func serveMcpStdioRejectsHTTPOutput() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "stdio", "--output", "json"], environment: [:])
    guard case .failure(.httpOnlyOption("output")) = result else {
        Issue.record("expected httpOnlyOption")
        return
    }
}

@Test
func serveMcpStdioRejectsListenHost() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "stdio", "--listen-host", "127.0.0.1"], environment: [:])
    guard case .failure(.httpOnlyOption("listen-host")) = result else {
        Issue.record("expected httpOnlyOption")
        return
    }
}

// MARK: - MCP HTTP tests

@Test
func serveMcpHTTPDefaults() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http"], environment: [:])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.transport == .http)
    #expect(config.listenHost == "127.0.0.1")
    #expect(config.listenPort == 8765)
    #expect(config.path == "/mcp")
    #expect(config.output == .human)
}

@Test
func serveMcpHTTPRejectsNonLoopback() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http", "--listen-host", "0.0.0.0"], environment: [:])
    guard case .failure(.nonLoopbackHTTPBinding("0.0.0.0")) = result else {
        Issue.record("expected nonLoopbackHTTPBinding")
        return
    }
}

@Test
func serveMcpHTTPAcceptsLocalhost() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http", "--listen-host", "localhost"], environment: [:])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.listenHost == "localhost")
}

@Test
func serveMcpHTTPRejectsInvalidPath() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http", "--path", "mcp"], environment: [:])
    guard case .failure(.invalidPath("mcp")) = result else {
        Issue.record("expected invalidPath")
        return
    }
}

@Test
func serveMcpHTTPAcceptsCustomPath() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http", "--path", "/api/mcp"], environment: [:])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.path == "/api/mcp")
}

// MARK: - Dev stack tests

@Test
func serveDevDefaults() {
    let result = AxolotyServeParser().parse(arguments: ["dev"], environment: [:])
    guard case .success(.development(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.mqtt.port == 1883)
    #expect(config.mcp.transport == .http)
    #expect(config.mcp.listenPort == 8765)
    #expect(config.mcp.brokerHost == "127.0.0.1")
    #expect(config.namespace == "-")
    #expect(config.output == .human)
}

@Test
func serveDevAcceptsNamespaceAndPorts() {
    let result = AxolotyServeParser().parse(arguments: ["dev", "--namespace", "example", "--mqtt-port", "2883", "--mcp-port", "9765"], environment: [:])
    guard case .success(.development(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.namespace == "example")
    #expect(config.mqtt.port == 2883)
    #expect(config.mcp.listenPort == 9765)
    #expect(config.mcp.brokerPort == 2883)
    #expect(config.mcp.namespace == "example")
}

@Test
func serveDevRejectsUnknownOption() {
    let result = AxolotyServeParser().parse(arguments: ["dev", "--tls"], environment: [:])
    guard case .failure(.unknownOption("tls")) = result else {
        Issue.record("expected unknownOption")
        return
    }
}

// MARK: - Subcommand routing tests

@Test
func serveWithNoSubcommandFails() {
    let result = AxolotyServeParser().parse(arguments: [], environment: [:])
    guard case .failure(.missingSubcommand) = result else {
        Issue.record("expected missingSubcommand")
        return
    }
}

@Test
func serveUnknownSubcommandFails() {
    let result = AxolotyServeParser().parse(arguments: ["unknown"], environment: [:])
    guard case .failure(.unknownSubcommand("unknown")) = result else {
        Issue.record("expected unknownSubcommand")
        return
    }
}

// MARK: - Environment variable tests

@Test
func serveMqttUsesEnvPort() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt"], environment: ["AXOLOTY_MQTT_PORT": "3883"])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.port == 3883)
}

@Test
func serveMcpUsesEnvBrokerHost() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "stdio"], environment: ["AXOLOTY_MQTT_HOST": "broker.local"])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.brokerHost == "broker.local")
}

@Test
func serveMcpUsesEnvNamespace() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "stdio"], environment: ["AXOLOTY_NAMESPACE": "test-ns"])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.namespace == "test-ns")
}

@Test
func serveMcpUsesEnvMCPHostAndPort() {
    let result = AxolotyServeParser().parse(arguments: ["mcp", "--transport", "http"], environment: ["AXOLOTY_MCP_HOST": "127.0.0.1", "AXOLOTY_MCP_PORT": "7777", "AXOLOTY_MCP_PATH": "/custom"])
    guard case .success(.mcp(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.listenHost == "127.0.0.1")
    #expect(config.listenPort == 7777)
    #expect(config.path == "/custom")
}

@Test
func serveDevUsesEnvNamespace() {
    let result = AxolotyServeParser().parse(arguments: ["dev"], environment: ["AXOLOTY_NAMESPACE": "env-ns"])
    guard case .success(.development(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.namespace == "env-ns")
}

@Test
func serveMqttCLIOverridesEnvPort() {
    let result = AxolotyServeParser().parse(arguments: ["mqtt", "--port", "4883"], environment: ["AXOLOTY_MQTT_PORT": "3883"])
    guard case .success(.mqtt(let config)) = result else {
        Issue.record("expected success")
        return
    }
    #expect(config.port == 4883)
}

// MARK: - Dispatcher integration tests

@Test(arguments: ["mqtt", "mcp", "dev"])
func dispatcherServeSubcommandHelpPrintsContextualUsage(subcommand: String) {
    let dispatcher = AxolotyCommandDispatcher(executableName: "ax", environment: [:])

    let result = dispatcher.run(arguments: ["serve", subcommand, "--help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: ax serve \(subcommand)"))
    #expect(result.standardOutput.contains("Options:"))
    #expect(result.standardError.isEmpty)
}

@Test
func dispatcherServesMqttReturns69WhenMosquittoMissing() {
    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: []),
        environment: [:],
        installSignalHandler: false
    )
    let result = dispatcher.run(arguments: ["serve", "mqtt"])
    #expect(result.exitCode == 69)
}

@Test
func dispatcherServesMcpStdioReturns69WhenMCPMissing() {
    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: []),
        environment: [:],
        installSignalHandler: false
    )
    let result = dispatcher.run(arguments: ["serve", "mcp", "--transport", "stdio"])
    #expect(result.exitCode == 69)
}

@Test
func dispatcherServesMcpMissingTransportReturnsError() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["serve", "mcp"])
    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("transport"))
}

@Test
func dispatcherServesDevReturns69WhenExecutablesMissing() {
    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: []),
        environment: [:],
        installSignalHandler: false
    )
    let result = dispatcher.run(arguments: ["serve", "dev"])
    #expect(result.exitCode == 69)
}

@Test
func dispatcherServeUnknownSubcommandReturnsError() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["serve", "unknown"])
    #expect(result.exitCode == 64)
}

@Test
func dispatcherVersionUsesExecutableName() {
    let dispatcher = AxolotyCommandDispatcher(executableName: "ax", environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "ax 0.2.0")
}

@Test
func dispatcherDefaultVersionIsAxolotyTool() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "axoloty-tool 0.2.0")
}

@Test
func dispatcherHelpIncludesServeCommands() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["help"])
    #expect(result.standardOutput.contains("serve mqtt"))
    #expect(result.standardOutput.contains("serve mcp"))
    #expect(result.standardOutput.contains("serve dev"))
}
