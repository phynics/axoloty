// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Fakes

private final class DevFakeProcessRunner: AxolotyManagedProcessRunning, @unchecked Sendable {
    var startSpec: ManagedProcessSpecification?
    var exitCode: Int32 = 0
    var wasTerminated = false
    var terminateCalled = false
    var forceKillCalled = false
    var running = false
    var terminateStopsProcess = true
    var forceKillStopsProcess = true
    var waitForExitCalled = false
    /// Number of ``isRunning`` polls before the fake process "exits".
    var pollsUntilExit: Int?

    private var pollCount = 0

    func start(_ specification: ManagedProcessSpecification) throws {
        startSpec = specification
        running = true
        pollCount = 0
    }

    func waitForExit(timeoutSeconds: TimeInterval) -> ManagedProcessExit? {
        waitForExitCalled = true
        guard !running else { return nil }
        running = false
        return ManagedProcessExit(exitCode: exitCode, wasTerminated: wasTerminated)
    }

    func terminate() {
        terminateCalled = true
        if terminateStopsProcess {
            running = false
        }
    }

    func forceKill() {
        forceKillCalled = true
        if forceKillStopsProcess {
            running = false
        }
    }

    var processIdentifier: Int32? { 12345 }
    var processDescription: String { startSpec?.executable ?? "fake-development-process" }
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

private struct DevPortProbe: AxolotyServiceProbing {
    var portAvailable = true
    var readyPorts: Set<UInt16> = []

    func isPortAvailable(host: String, port: UInt16) -> Bool { portAvailable }
    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        readyPorts.contains(port)
    }
}

private final class DevInjectedSignalHandler: ServiceSignalHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private(set) var installCalled = false
    private(set) var uninstallCalled = false
    private let onInterrupt: @Sendable () -> Void

    init(onInterrupt: @escaping @Sendable () -> Void) {
        self.onInterrupt = onInterrupt
    }

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func install() {
        lock.lock()
        installCalled = true
        lock.unlock()
    }

    func uninstall() {
        lock.lock()
        uninstallCalled = true
        lock.unlock()
    }

    func lifecycleSnapshot() -> (installCalled: Bool, uninstallCalled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (installCalled, uninstallCalled)
    }

    func interrupt() {
        lock.lock()
        let shouldNotify = !interrupted
        interrupted = true
        lock.unlock()

        if shouldNotify {
            onInterrupt()
        }
    }
}

private final class DevInjectedSignalSource: ServiceSignalHandlerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: DevInjectedSignalHandler?

    func makeHandler(onInterrupt: @escaping @Sendable () -> Void) -> any ServiceSignalHandling {
        let handler = DevInjectedSignalHandler(onInterrupt: onInterrupt)
        lock.lock()
        self.handler = handler
        lock.unlock()
        return handler
    }

    func interrupt() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?.interrupt()
    }

    func lifecycle() -> (installCalled: Bool, uninstallCalled: Bool) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        return handler?.lifecycleSnapshot() ?? (false, false)
    }
}

private final class DevStartupSignalPortProbe: AxolotyServiceProbing, @unchecked Sendable {
    private let signalSource: DevInjectedSignalSource
    private let lock = NSLock()
    private var didSendSignal = false

    init(signalSource: DevInjectedSignalSource) {
        self.signalSource = signalSource
    }

    func isPortAvailable(host: String, port: UInt16) -> Bool { true }

    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        lock.lock()
        let shouldSendSignal = !didSendSignal
        didSendSignal = true
        lock.unlock()

        if shouldSendSignal {
            signalSource.interrupt()
        }
        return true
    }
}

private final class DevTempDirProvider: AxolotyTempDirectoryProvider, @unchecked Sendable {
    func createTempDirectory() throws -> String {
        let path = "/tmp/dev-axoloty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        return path
    }

    func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class AnyRunnerSource: @unchecked Sendable {
    private var queue: [any AxolotyManagedProcessRunning]

    init(_ runners: [any AxolotyManagedProcessRunning]) {
        queue = runners
    }

    func makeRunner() -> any AxolotyManagedProcessRunning {
        queue.removeFirst()
    }
}

private func devFakeFactory(_ runners: [DevFakeProcessRunner]) -> @Sendable () -> any AxolotyManagedProcessRunning {
    let source = AnyRunnerSource(runners)
    return { source.makeRunner() }
}

private func devConfiguration() -> DevelopmentServiceConfiguration {
    DevelopmentServiceConfiguration(
        mqtt: MQTTServiceConfiguration(),
        mcp: MCPServiceConfiguration(transport: .http),
        namespace: "test",
        output: .human
    )
}

// MARK: - Startup and readiness

@Test
func devServiceStartsBothAndExitsWhenMCPExitsCleanly() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()
    mcpRunner.exitCode = 0
    mcpRunner.pollsUntilExit = 2

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 0)
    #expect(mqttRunner.startSpec?.executable == "/usr/sbin/mosquitto")
    #expect(mcpRunner.startSpec?.executable == "/opt/axoloty/bin/axoloty-mcp")
    let args = mcpRunner.startSpec?.arguments ?? []
    #expect(args.contains("--transport"))
    #expect(args.contains("http"))
    #expect(mqttRunner.terminateCalled)
}

@Test
func devServiceWritesJSONReadinessToStandardOutputOnly() throws {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()
    mcpRunner.pollsUntilExit = 2
    let capture = ToolingServiceOutputCapture()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false,
        standardOutput: capture.standardOutput,
        standardError: capture.standardError
    )

    let configuration = DevelopmentServiceConfiguration(
        mqtt: MQTTServiceConfiguration(),
        mcp: MCPServiceConfiguration(transport: .http),
        namespace: "test",
        output: .json
    )
    let exitCode = runner.run(configuration)
    let streams = capture.read()

    #expect(exitCode == 0)
    #expect(streams.standardError.isEmpty)
    let manifest = try decodeServiceJSONObject(streams.standardOutput)
    #expect(manifest["status"] as? String == "ready")
    let services = try #require(manifest["services"] as? [String: Any])
    let mqtt = try #require(services["mqtt"] as? [String: Any])
    let mcp = try #require(services["mcp"] as? [String: Any])
    #expect(mqtt["url"] as? String == "mqtt://127.0.0.1:1883")
    #expect(mcp["url"] as? String == "http://127.0.0.1:8765/mcp")
}

@Test
func devServiceFailsWhenMosquittoMissing() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: []),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 69)
    #expect(mqttRunner.startSpec == nil)
    #expect(mcpRunner.startSpec == nil)
}

@Test
func devServiceWritesJSONFailureDiagnosticsToStandardErrorOnly() throws {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()
    let capture = ToolingServiceOutputCapture()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: []),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false,
        standardOutput: capture.standardOutput,
        standardError: capture.standardError
    )

    let configuration = DevelopmentServiceConfiguration(
        mqtt: MQTTServiceConfiguration(),
        mcp: MCPServiceConfiguration(transport: .http),
        namespace: "test",
        output: .json
    )
    let exitCode = runner.run(configuration)
    let streams = capture.read()

    #expect(exitCode == 69)
    #expect(streams.standardOutput.isEmpty)
    let diagnostic = try decodeServiceJSONObject(streams.standardError)
    #expect(diagnostic["level"] as? String == "error")
    #expect(diagnostic["message"] as? String == "mosquitto executable not found at /usr/sbin/mosquitto")
    let metadata = try #require(diagnostic["metadata"] as? [String: Any])
    #expect(metadata["executable"] as? String == "/usr/sbin/mosquitto")
}

@Test
func devServiceFailsWhenMCPExecutableMissing() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 69)
    #expect(mqttRunner.startSpec == nil)
    #expect(mcpRunner.startSpec == nil)
}

@Test
func devServiceFailsWhenMQTTNotReady() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: []),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 70)
    #expect(mqttRunner.forceKillCalled)
    #expect(mcpRunner.startSpec == nil)
}

@Test
func devServiceTerminatesMQTTWhenMCPNotReady() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 70)
    #expect(mcpRunner.forceKillCalled)
    #expect(mqttRunner.forceKillCalled)
}

// MARK: - Cross-process supervision

@Test
func devServiceTerminatesMCPWhenMQTTExits() {
    let mqttRunner = DevFakeProcessRunner()
    mqttRunner.exitCode = 1
    mqttRunner.pollsUntilExit = 2
    let mcpRunner = DevFakeProcessRunner()

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 1)
    #expect(mcpRunner.terminateCalled)
    #expect(mcpRunner.forceKillCalled == false)
}

@Test
func devServiceReturnsMCPExitStatusWhenMCPExits() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()
    mcpRunner.exitCode = 3
    mcpRunner.pollsUntilExit = 2

    let runner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let exitCode = runner.run(devConfiguration())
    #expect(exitCode == 3)
    #expect(mqttRunner.terminateCalled)
}

@Test
func managedProcessSupervisorEscalatesAfterGracePeriod() {
    let processRunner = DevFakeProcessRunner()
    processRunner.running = true
    processRunner.terminateStopsProcess = false

    let supervisor = ManagedProcessSupervisor(shutdownTimeout: 0, reapTimeout: 0.01)
    supervisor.register(processRunner)
    _ = supervisor.terminateAndWait()

    #expect(processRunner.terminateCalled)
    #expect(processRunner.forceKillCalled)
    #expect(processRunner.waitForExitCalled)
}

@Test
func managedProcessSupervisorReportsUnreapedRunnerWithoutBlocking() {
    let processRunner = DevFakeProcessRunner()
    processRunner.running = true
    processRunner.terminateStopsProcess = false
    processRunner.forceKillStopsProcess = false

    let supervisor = ManagedProcessSupervisor(shutdownTimeout: 0, reapTimeout: 0.01)
    supervisor.register(processRunner)
    let report = supervisor.terminateAndWait()

    #expect(report.failures.count == 1)
    #expect(report.failures.first?.processIdentifier == 12345)
    #expect(report.failures.first?.phase == "reap-timeout")
}

struct DevelopmentServiceSignalLifecycleTests {
    @Test
    func devServiceCleansUpChildWhenInterruptedDuringStartup() {
        let mqttRunner = DevFakeProcessRunner()
        let mcpRunner = DevFakeProcessRunner()
        let signalSource = DevInjectedSignalSource()

        let runner = AxolotyDevelopmentServiceRunner(
            processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
            portProbe: DevStartupSignalPortProbe(signalSource: signalSource),
            fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
            tempDirProvider: DevTempDirProvider(),
            installSignalHandler: true,
            signalHandlerFactory: signalSource
        )

        let exitCode = runner.run(devConfiguration())

        #expect(exitCode == 130)
        #expect(mqttRunner.terminateCalled)
        #expect(mqttRunner.waitForExitCalled)
        #expect(mcpRunner.startSpec == nil)
        let lifecycle = signalSource.lifecycle()
        #expect(lifecycle.installCalled)
        #expect(lifecycle.uninstallCalled)
    }
}

// MARK: - Dispatcher integration

@Test
func dispatcherServeDevWithFakeDepsReturnsExitCode() {
    let mqttRunner = DevFakeProcessRunner()
    let mcpRunner = DevFakeProcessRunner()
    mcpRunner.exitCode = 0
    mcpRunner.pollsUntilExit = 2

    let dispatcher = AxolotyCommandDispatcher(
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", "/opt/axoloty/bin/axoloty-mcp"]),
        environment: [:],
        processRunnerFactory: devFakeFactory([mqttRunner, mcpRunner]),
        portProbe: DevPortProbe(readyPorts: [1883, 8765]),
        tempDirProvider: DevTempDirProvider(),
        installSignalHandler: false
    )

    let result = dispatcher.run(arguments: ["serve", "dev"])
    #expect(result.exitCode == 0)
    #expect(mqttRunner.terminateCalled)
}

// MARK: - End-to-end with real processes

/// Binds a loopback socket to an ephemeral port and returns the assigned port.
private func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, 1, 0)  // SOCK_STREAM
    guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CocoaError(.fileWriteUnknown) }

    var name = sockaddr_in()
    var nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getResult = withUnsafeMutablePointer(to: &name) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &nameLen)
        }
    }
    guard getResult == 0 else { throw CocoaError(.fileReadUnknown) }
    return UInt16(bigEndian: name.sin_port)
}

/// Creates a listening loopback socket on an ephemeral port.
private func listeningLoopbackSocket(host: String) throws -> (fd: Int32, port: UInt16) {
    if host == "::1" {
        let fd = socket(AF_INET6, 1, 0) // SOCK_STREAM
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }

        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        inet_pton(AF_INET6, "::1", &address.sin6_addr)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteUnknown)
        }

        var boundAddress = sockaddr_in6()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &addressLength)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw CocoaError(.fileReadUnknown)
        }
        return (fd, UInt16(bigEndian: boundAddress.sin6_port))
    }

    let fd = socket(AF_INET, 1, 0) // SOCK_STREAM
    guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    inet_pton(AF_INET, host, &address.sin_addr)
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0, listen(fd, 1) == 0 else {
        close(fd)
        throw CocoaError(.fileWriteUnknown)
    }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(fd, socketAddress, &addressLength)
        }
    }
    guard nameResult == 0 else {
        close(fd)
        throw CocoaError(.fileReadUnknown)
    }
    return (fd, UInt16(bigEndian: boundAddress.sin_port))
}

private func ipv6LoopbackAvailable() -> Bool {
    guard let listener = try? listeningLoopbackSocket(host: "::1") else { return false }
    close(listener.fd)
    return true
}

@Test
func foundationServiceProbeConnectsToIPv4Loopback() throws {
    let listener = try listeningLoopbackSocket(host: "127.0.0.1")
    defer { close(listener.fd) }
    #expect(FoundationServiceProbe().waitForTCP(host: "127.0.0.1", port: listener.port, timeoutSeconds: 1))
}

@Test
func foundationServiceProbeConnectsToLocalhost() throws {
    let probe = FoundationServiceProbe()
    var connected = false
    if let listener = try? listeningLoopbackSocket(host: "127.0.0.1") {
        connected = probe.waitForTCP(host: "localhost", port: listener.port, timeoutSeconds: 1)
        close(listener.fd)
    }
    if !connected, ipv6LoopbackAvailable(), let listener = try? listeningLoopbackSocket(host: "::1") {
        connected = probe.waitForTCP(host: "localhost", port: listener.port, timeoutSeconds: 1)
        close(listener.fd)
    }
    #expect(connected)
}

@Test(.enabled(if: ipv6LoopbackAvailable()))
func foundationServiceProbeConnectsToIPv6Loopback() throws {
    let listener = try listeningLoopbackSocket(host: "::1")
    defer { close(listener.fd) }
    #expect(FoundationServiceProbe().waitForTCP(host: "::1", port: listener.port, timeoutSeconds: 1))
}

@Test
func foundationServiceProbeReportsOccupiedIPv4PortUnavailable() throws {
    let listener = try listeningLoopbackSocket(host: "127.0.0.1")
    defer { close(listener.fd) }
    #expect(!FoundationServiceProbe().isPortAvailable(host: "127.0.0.1", port: listener.port))
}

@Test(.enabled(if: ipv6LoopbackAvailable()))
func foundationServiceProbeReportsOccupiedIPv6PortUnavailable() throws {
    let listener = try listeningLoopbackSocket(host: "::1")
    defer { close(listener.fd) }
    #expect(!FoundationServiceProbe().isPortAvailable(host: "::1", port: listener.port))
}

@Test
func urlAuthorityHostBracketsIPv6Literals() {
    #expect(urlAuthorityHost("::1") == "[::1]")
    #expect(urlAuthorityHost("127.0.0.1") == "127.0.0.1")
    #expect(urlAuthorityHost("localhost") == "localhost")
}

/// Locates a runnable ``axoloty-mcp`` binary for integration testing.
private func mcpExecutablePath() -> String? {
    if let configured = ProcessInfo.processInfo.environment["AXOLOTY_MCP_EXECUTABLE"],
       FileManager.default.isExecutableFile(atPath: configured) {
        return configured
    }
    var candidates: [String] = []
    if let argvZero = CommandLine.arguments.first {
        candidates.append(
            URL(fileURLWithPath: argvZero)
                .deletingLastPathComponent()
                .appendingPathComponent("axoloty-mcp")
                .path
        )
    }
    candidates.append(contentsOf: [
        ".build/debug/axoloty-mcp",
        ".build/x86_64-unknown-linux-gnu/debug/axoloty-mcp",
    ])
    // The image path is a swift-run launcher, not a compiled executable. Using
    // it from this SwiftPM test would contend with the parent test process for
    // the same build directory, so the test only selects a built product.
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Captures the exit code reported by a background runner thread.
private final class ExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = -1
    func set(_ newValue: Int32) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Returns whether the live development-service evidence was explicitly requested.
private func developmentServiceEndToEndIsEnabled(environment: [String: String]) -> Bool {
    environment["AXOLOTY_RUN_DEV_SERVICE_E2E"] == "1"
}

@Test(.enabled(
    if: developmentServiceEndToEndIsEnabled(environment: ProcessInfo.processInfo.environment),
    "Set AXOLOTY_RUN_DEV_SERVICE_E2E=1 to run local Mosquitto and MCP evidence."
))
func devServiceEndToEndWithDynamicPorts() throws {
    guard let mcpPath = mcpExecutablePath() else { return }
    guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/mosquitto") else { return }

    let mqttPort = try freePort()
    let mcpPort = try freePort()

    let mqttRunner = FoundationProcessRunner()
    let mcpRunner = FoundationProcessRunner()
    let source = AnyRunnerSource([mqttRunner, mcpRunner])
    let configuration = DevelopmentServiceConfiguration(
        mqtt: MQTTServiceConfiguration(port: mqttPort),
        mcp: MCPServiceConfiguration(
            transport: .http,
            listenPort: mcpPort,
            brokerPort: mqttPort,
            namespace: "e2e"
        ),
        namespace: "e2e",
        output: .json
    )

    let devRunner = AxolotyDevelopmentServiceRunner(
        processRunnerFactory: { source.makeRunner() },
        portProbe: FoundationServiceProbe(),
        fileSystem: StubFileSystem(paths: ["/usr/sbin/mosquitto", mcpPath]),
        mosquittoExecutable: "/usr/sbin/mosquitto",
        mcpExecutable: mcpPath,
        installSignalHandler: false
    )

    let exitBox = ExitCodeBox()
    let exited = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        // Swift concurrency worker threads block most signals, so supervised
        // children spawned from them never process SIGTERM. Reset this thread's
        // mask before starting Mosquitto and axoloty-mcp so they shut down
        // cleanly when terminate() is called.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        pthread_sigmask(SIG_SETMASK, &emptyMask, nil)
        exitBox.set(devRunner.run(configuration))
        exited.signal()
    }

    defer {
        mqttRunner.forceKill()
        mcpRunner.forceKill()
    }

    let probe = FoundationServiceProbe()
    let mqttReady = probe.waitForTCP(host: "127.0.0.1", port: mqttPort, timeoutSeconds: 20.0)
    #expect(mqttReady)
    let mcpReady = probe.waitForTCP(host: "127.0.0.1", port: mcpPort, timeoutSeconds: 20.0)
    #expect(mcpReady)

    guard mqttReady, mcpReady else { return }

    Thread.sleep(forTimeInterval: 0.5)

    mqttRunner.terminate()

    let waitResult = exited.wait(timeout: .now() + 20)
    #expect(waitResult == .success)
    #expect(exitBox.get() == 0)
    #expect(!mqttRunner.isRunning)
    #expect(!mcpRunner.isRunning)
}
