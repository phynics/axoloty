// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation
import Testing

// MARK: - Fakes

private final class FakeProcessRunner: AxolotyManagedProcessRunning, @unchecked Sendable {
    var startSpec: ManagedProcessSpecification?
    var exitCode: Int32 = 0
    var wasTerminated = false
    var terminateCalled = false
    var forceKillCalled = false
    var running = false
    /// Number of ``isRunning`` polls before the fake process "exits".
    var pollsUntilExit: Int?

    private var pollCount = 0

    func start(_ specification: ManagedProcessSpecification) throws {
        startSpec = specification
        running = true
        pollCount = 0
    }

    func waitForExit() -> ManagedProcessExit {
        running = false
        return ManagedProcessExit(exitCode: exitCode, wasTerminated: wasTerminated)
    }

    func terminate() {
        terminateCalled = true
        running = false
    }

    func forceKill() {
        forceKillCalled = true
        running = false
    }

    var processIdentifier: Int32? { 12345 }
    var isRunning: Bool {
        guard running else { return false }
        if let pollsUntilExit {
            pollCount += 1
            if pollCount >= pollsUntilExit {
                running = false
            }
        }
        return running
    }
}

private final class FakePortProbe: AxolotyServiceProbing, @unchecked Sendable {
    var portAvailable = true
    var tcpReady = true
    var lastTimeoutSeconds: Double?

    init(portAvailable: Bool = true, tcpReady: Bool = true) {
        self.portAvailable = portAvailable
        self.tcpReady = tcpReady
    }

    func isPortAvailable(host: String, port: UInt16) -> Bool { portAvailable }
    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        lastTimeoutSeconds = timeoutSeconds
        return tcpReady
    }
}

private final class FakeTempDirProvider: AxolotyTempDirectoryProvider, @unchecked Sendable {
    var createdPaths: [String] = []
    var removedPaths: [String] = []

    func createTempDirectory() throws -> String {
        let path = "/tmp/fake-axoloty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        createdPaths.append(path)
        return path
    }

    func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        removedPaths.append(path)
    }
}

private struct MQTTStubFileSystem: AxolotyFileSystem {
    let paths: Set<String>
    func exists(atPath path: String) -> Bool { paths.contains(path) }
}

// MARK: - Mosquitto config tests

@Test
func mosquittoConfigContainsListenerAndAnonymous() {
    let config = MosquittoConfigGenerator().generate(
        listenHost: "127.0.0.1",
        port: 1883,
        logLevel: .info
    )
    #expect(config.contains("listener 1883 127.0.0.1"))
    #expect(config.contains("allow_anonymous true"))
    #expect(config.contains("persistence false"))
    #expect(config.contains("log_dest stderr"))
}

@Test
func mosquittoConfigDebugIncludesConnectionMessages() {
    let config = MosquittoConfigGenerator().generate(
        listenHost: "127.0.0.1",
        port: 1883,
        logLevel: .debug
    )
    #expect(config.contains("log_type all"))
    #expect(config.contains("connection_messages true"))
}

@Test
func mosquittoConfigErrorOnlyIncludesErrorLogType() {
    let config = MosquittoConfigGenerator().generate(
        listenHost: "127.0.0.1",
        port: 1883,
        logLevel: .error
    )
    #expect(config.contains("log_type error"))
    #expect(!config.contains("connection_messages"))
}

@Test
func mosquittoConfigSupportsZeroPointZeroForContainer() {
    let config = MosquittoConfigGenerator().generate(
        listenHost: "0.0.0.0",
        port: 1883,
        logLevel: .info
    )
    #expect(config.contains("listener 1883 0.0.0.0"))
}

// MARK: - MQTT service runner tests

@Test
func mqttServiceFailsWhenMosquittoMissing() {
    let runner = AxolotyMQTTServiceRunner(
        processRunner: FakeProcessRunner(),
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: []),
        tempDirProvider: FakeTempDirProvider(),
        mosquittoExecutable: "/nonexistent/mosquitto"
    )
    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 69)
}

@Test
func mqttServiceFailsWhenPortInUse() {
    let runner = AxolotyMQTTServiceRunner(
        processRunner: FakeProcessRunner(),
        portProbe: FakePortProbe(portAvailable: false),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: FakeTempDirProvider(),
        mosquittoExecutable: "/usr/sbin/mosquitto",
        installSignalHandler: false
    )
    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 69)
}

@Test
func mqttServiceStartsAndExitsCleanly() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let tempProvider = FakeTempDirProvider()
    let runner = AxolotyMQTTServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: tempProvider,
        mosquittoExecutable: "/usr/sbin/mosquitto",
        installSignalHandler: false
    )

    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 0)
    #expect(processRunner.startSpec?.executable == "/usr/sbin/mosquitto")
    #expect(processRunner.startSpec?.arguments.count == 2)
    #expect(processRunner.startSpec?.arguments.first == "-c")
    #expect(tempProvider.createdPaths.count == 1)
    #expect(tempProvider.removedPaths.count == 1)
}

@Test
func mqttServiceFailsWhenNotReady() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true

    let runner = AxolotyMQTTServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(tcpReady: false),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: FakeTempDirProvider(),
        mosquittoExecutable: "/usr/sbin/mosquitto",
        installSignalHandler: false
    )

    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 70)
    #expect(processRunner.forceKillCalled)
}

@Test
func mqttServiceReturns1OnChildCrash() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 1
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let runner = AxolotyMQTTServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: FakeTempDirProvider(),
        mosquittoExecutable: "/usr/sbin/mosquitto",
        installSignalHandler: false
    )

    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 1)
}

// MARK: - MCP service runner tests

@Test
func mcpServiceFailsWhenExecutableMissing() {
    let runner = AxolotyMCPServiceRunner(
        processRunner: FakeProcessRunner(),
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: []),
        mcpExecutable: "/nonexistent/axoloty-mcp"
    )
    let exitCode = runner.run(MCPServiceConfiguration(transport: .stdio))
    #expect(exitCode == 69)
}

@Test
func mcpServiceStdioStartsAndExitsCleanly() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let runner = AxolotyMCPServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        mcpExecutable: "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: false
    )

    let exitCode = runner.run(MCPServiceConfiguration(transport: .stdio, brokerHost: "localhost", brokerPort: 1883, namespace: "test"))
    #expect(exitCode == 0)
    #expect(processRunner.startSpec?.executable == "/opt/axoloty/bin/axoloty-mcp")
    let args = processRunner.startSpec?.arguments ?? []
    #expect(args.contains("--transport"))
    #expect(args.contains("stdio"))
    #expect(args.contains("--broker-host"))
    #expect(args.contains("localhost"))
    #expect(args.contains("--connect-timeout"))
    #expect(args.contains("10s"))
}

@Test
func mcpServiceForwardsConfiguredConnectTimeout() {
    let processRunner = FakeProcessRunner()
    let portProbe = FakePortProbe()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 1

    let runner = AxolotyMCPServiceRunner(
        processRunner: processRunner,
        portProbe: portProbe,
        fileSystem: MQTTStubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        mcpExecutable: "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: false
    )

    _ = runner.run(MCPServiceConfiguration(transport: .http, connectTimeout: "37s"))
    let args = processRunner.startSpec?.arguments ?? []
    guard let index = args.firstIndex(of: "--connect-timeout") else {
        Issue.record("expected connect-timeout argument")
        return
    }
    #expect(args[index + 1] == "37s")
    #expect(portProbe.lastTimeoutSeconds == 42)
}

@Test
func mcpServiceHTTPFailsWhenNotReady() {
    let processRunner = FakeProcessRunner()
    processRunner.running = true

    let runner = AxolotyMCPServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(tcpReady: false),
        fileSystem: MQTTStubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        mcpExecutable: "/opt/axoloty/bin/axoloty-mcp"
    )

    let exitCode = runner.run(MCPServiceConfiguration(transport: .http, brokerHost: "localhost", brokerPort: 1883, namespace: "test"))
    #expect(exitCode == 70)
    #expect(processRunner.forceKillCalled)
}

@Test
func mcpServiceHTTPStartsAndExitsCleanly() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let runner = AxolotyMCPServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        mcpExecutable: "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: false
    )

    let exitCode = runner.run(MCPServiceConfiguration(transport: .http, listenHost: "127.0.0.1", listenPort: 8765, path: "/mcp", brokerHost: "localhost", brokerPort: 1883, namespace: "test"))
    #expect(exitCode == 0)
    let args = processRunner.startSpec?.arguments ?? []
    #expect(args.contains("--transport"))
    #expect(args.contains("http"))
    #expect(args.contains("--listen-host"))
    #expect(args.contains("--listen-port"))
    #expect(args.contains("8765"))
}

@Test
func mcpServiceReturns1OnChildCrash() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 1
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let runner = AxolotyMCPServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        mcpExecutable: "/opt/axoloty/bin/axoloty-mcp",
        installSignalHandler: false
    )

    let exitCode = runner.run(MCPServiceConfiguration(transport: .stdio, brokerHost: "localhost", brokerPort: 1883, namespace: "test"))
    #expect(exitCode == 1)
}

// MARK: - Dispatcher integration for MCP

@Test
func dispatcherServeMcpWithFakeDepsReturnsExitCode() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: ["/opt/axoloty/bin/axoloty-mcp"]),
        environment: [:],
        processRunnerFactory: { processRunner },
        portProbe: FakePortProbe(),
        tempDirProvider: FakeTempDirProvider(),
        installSignalHandler: false
    )

    let result = dispatcher.run(arguments: ["serve", "mcp", "--transport", "stdio"])
    #expect(result.exitCode == 0)
}

// MARK: - Dispatcher integration

@Test
func dispatcherServeMqttWithFakeDepsReturnsExitCode() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true
    processRunner.pollsUntilExit = 2

    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        environment: [:],
        processRunnerFactory: { processRunner },
        portProbe: FakePortProbe(),
        tempDirProvider: FakeTempDirProvider(),
        installSignalHandler: false
    )

    let result = dispatcher.run(arguments: ["serve", "mqtt"])
    #expect(result.exitCode == 0)
}
