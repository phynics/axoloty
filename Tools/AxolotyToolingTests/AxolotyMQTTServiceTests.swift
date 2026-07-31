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

    func start(_ specification: ManagedProcessSpecification) throws {
        startSpec = specification
        running = true
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
    var isRunning: Bool { running }
}

private struct FakePortProbe: AxolotyServiceProbing {
    var portAvailable = true
    var tcpReady = true

    func isPortAvailable(host: String, port: UInt16) -> Bool { portAvailable }
    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool { tcpReady }
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
        mosquittoExecutable: "/usr/sbin/mosquitto"
    )
    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 69)
}

@Test
func mqttServiceStartsAndExitsCleanly() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true

    let tempProvider = FakeTempDirProvider()
    let runner = AxolotyMQTTServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: tempProvider,
        mosquittoExecutable: "/usr/sbin/mosquitto"
    )

    // Simulate process exiting after readiness by setting running=false
    // The runner polls isRunning in a loop; once false it calls waitForExit.
    // We need to set running=false after a brief delay to simulate the process exiting.
    _Concurrency.Task {
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))
        processRunner.running = false
    }

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
        mosquittoExecutable: "/usr/sbin/mosquitto"
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

    let runner = AxolotyMQTTServiceRunner(
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: FakeTempDirProvider(),
        mosquittoExecutable: "/usr/sbin/mosquitto"
    )

    // Simulate process exiting after readiness
    _Concurrency.Task {
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))
        processRunner.running = false
    }

    let exitCode = runner.run(MQTTServiceConfiguration())
    #expect(exitCode == 1)
}

// MARK: - Dispatcher integration

@Test
func dispatcherServeMqttWithFakeDepsReturnsExitCode() {
    let processRunner = FakeProcessRunner()
    processRunner.exitCode = 0
    processRunner.running = true

    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: MQTTStubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        environment: [:],
        processRunner: processRunner,
        portProbe: FakePortProbe(),
        tempDirProvider: FakeTempDirProvider()
    )

    _Concurrency.Task {
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))
        processRunner.running = false
    }

    let result = dispatcher.run(arguments: ["serve", "mqtt"])
    #expect(result.exitCode == 0)
}
