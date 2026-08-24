// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyProcessLauncher

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(Glibc)
private let lifecyclePollIn = Int16(Glibc.POLLIN)
private let lifecyclePollHup = Int16(Glibc.POLLHUP)
private let lifecyclePollErr = Int16(Glibc.POLLERR)
#else
private let lifecyclePollIn = Int16(Darwin.POLLIN)
private let lifecyclePollHup = Int16(Darwin.POLLHUP)
private let lifecyclePollErr = Int16(Darwin.POLLERR)
#endif

// swiftlint:disable type_body_length file_length function_body_length function_parameter_count optional_data_string_conversion
final class FoundationCommandExecution: @unchecked Sendable {
    private let environment: [String: String]
    private let configuration: AxolotyCommandRunnerConfiguration
    private let cancellation: AxolotyCommandCancellation
    private let artifactStore: AxolotyCommandArtifactStore
    private let readerShutdownGrace: TimeInterval = 2

    init(
        environment: [String: String],
        configuration: AxolotyCommandRunnerConfiguration,
        cancellation: AxolotyCommandCancellation,
        artifactStore: AxolotyCommandArtifactStore
    ) {
        self.environment = environment
        self.configuration = configuration
        self.cancellation = cancellation
        self.artifactStore = artifactStore
    }

    func run(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) throws -> AxolotyCheckCommandResult {
        let startedAt = Date()
        let clock = ContinuousClock()
        let clockStartedAt = clock.now
        let timeout = command.timeoutSeconds ?? configuration.commandTimeout
        if let timeout,
           let reason = AxolotyCommandRunnerConfiguration.timeoutValidationReason(timeout) {
            let result = AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: "invalid_lifecycle_configuration: option=commandTimeout reason=\(reason)\n"
            )
            return result
        }
        let deadline = timeout.map { startedAt.addingTimeInterval($0) }
        let clockDeadline = timeout.map {
            clockStartedAt.advanced(by: .nanoseconds(Int64($0 * 1_000_000_000)))
        }
        let artifact = try artifactStore.begin(
            command: command,
            context: context,
            startedAt: startedAt,
            deadline: deadline
        )
        let streamedStreams: Set<AxolotyCommandOutputStream> = configuration.outputMode == .human
            ? [.standardOutput, .standardError]
            : [.standardError]
        let collector = AxolotyCommandOutputCollector(
            streamOutput: configuration.streamOutput,
            streamedStreams: streamedStreams
        )

        if cancellation.isCancelled {
            return cancelledBeforeStart(
                command: command,
                context: context,
                startedAt: startedAt,
                deadline: deadline,
                collector: collector,
                artifact: artifact
            )
        }

        let resources: CommandProcessResources
        do {
            resources = try launchProcess(command)
        } catch {
            let result = AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start command \(command.executable): \(error.localizedDescription)"
            )
            artifactStore.finish(
                artifact,
                startedAt: startedAt,
                finishedAt: Date(),
                result: result,
                standardOutput: Data(),
                standardError: Data(result.standardError.utf8),
                additionalEnvironment: environment.merging(command.environment) { _, value in value }
            )
            return result
        }

        let process = resources.process
        let processGroupID = resources.processGroupID
        let readers = startReaders(
            stdout: resources.stdout,
            stderr: resources.stderr,
            collector: collector
        )

        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let heartbeatHandler: @Sendable () -> Void = { [context, collector] in
            let snapshot = collector.diagnosticSnapshot()
            Self.emitHeartbeat(
                context: context,
                startedAt: startedAt,
                lastTest: snapshot.lastTest,
                outputBytes: snapshot.outputBytes,
                collector: collector
            )
        }
        heartbeat.setEventHandler(handler: heartbeatHandler)
        heartbeat.schedule(
            deadline: .now(),
            repeating: configuration.heartbeatInterval,
            leeway: .milliseconds(10)
        )
        heartbeat.resume()
        defer { heartbeat.cancel() }

        var interruption: AxolotyCommandLifecycleOutcome?
        while process.isRunning {
            if cancellation.isCancelled {
                interruption = .cancelled
                break
            }
            if let clockDeadline, clock.now >= clockDeadline {
                interruption = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if let interruption {
            let termination = terminateAndReap(
                process: process,
                processGroupID: processGroupID,
                readers: readers
            )
            collector.finishLines()
            let result = Self.interruptedResult(
                outcome: interruption,
                context: context,
                startedAt: startedAt,
                deadline: deadline,
                collector: collector,
                artifact: artifact,
                escalatedToKill: termination.escalatedToKill
            )
            artifactStore.finish(
                artifact,
                startedAt: startedAt,
                finishedAt: Date(),
                result: result,
                standardOutput: Data(result.standardOutput.utf8),
                standardError: Data(result.standardError.utf8),
                progress: collector.progressData(),
                additionalEnvironment: environment.merging(command.environment) { _, value in value }
            )
            return result
        }

        process.waitUntilExit()
        return completeProcess(CommandExecutionState(
            process: process,
            processGroupID: processGroupID,
            readers: readers,
            deadline: deadline,
            clockDeadline: clockDeadline,
            cancellation: cancellation,
            collector: collector,
            command: command,
            context: context,
            startedAt: startedAt,
            artifact: artifact
        ))
    }

    private func completeProcess(_ state: CommandExecutionState) -> AxolotyCheckCommandResult {
        if let interruption = waitForReaders(
            state.readers,
            deadline: state.clockDeadline,
            cancellation: state.cancellation
        ) {
            let termination = terminateAndReap(
                process: state.process,
                processGroupID: state.processGroupID,
                readers: state.readers
            )
            state.collector.finishLines()
            let result = Self.interruptedResult(
                outcome: interruption,
                context: state.context,
                startedAt: state.startedAt,
                deadline: state.deadline,
                collector: state.collector,
                artifact: state.artifact,
                escalatedToKill: termination.escalatedToKill
            )
            finishArtifact(state, result: result)
            return result
        }
        state.collector.finishLines()
        let standardOutput = state.collector.data(for: .standardOutput)
        let standardError = state.collector.data(for: .standardError)
        let processExitCode = state.process.terminationStatus
        let emptyTestRun = processExitCode == 0
            && Self.isSwiftTestCommand(state.command)
            && Self.didRunZeroTests(standardOutput: standardOutput, standardError: standardError)
        let emptyTestDiagnostic = emptyTestRun
            ? "test command executed zero non-skipped tests; refusing to treat an empty test run as success\n"
            : ""
        let result = AxolotyCheckCommandResult(
            exitCode: emptyTestRun ? 65 : processExitCode,
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self) + emptyTestDiagnostic
        )
        finishArtifact(
            state,
            result: result,
            standardOutput: standardOutput,
            standardError: standardError
        )
        return result
    }

    private static func isSwiftTestCommand(_ command: AxolotyCommandPlan) -> Bool {
        URL(fileURLWithPath: command.executable).lastPathComponent == "swift"
            && command.arguments.first == "test"
    }

    private static func didRunZeroTests(standardOutput: Data, standardError: Data) -> Bool {
        let output = String(decoding: standardOutput, as: UTF8.self)
        let error = String(decoding: standardError, as: UTF8.self)
        let passedIndividualTest = output.split(separator: "\n").contains { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            return candidate.hasPrefix("✔ Test ") && !candidate.hasPrefix("✔ Test run")
        }
        return error.contains("warning: No matching test cases were run")
            || output.contains("Test run with 0 tests in 0 suites")
            || (output.contains("➜ Test ")
                && output.contains(" skipped.")
                && !passedIndividualTest)
    }

    private func finishArtifact(
        _ state: CommandExecutionState,
        result: AxolotyCheckCommandResult,
        standardOutput: Data? = nil,
        standardError: Data? = nil
    ) {
        artifactStore.finish(
            state.artifact,
            startedAt: state.startedAt,
            finishedAt: Date(),
            result: result,
            standardOutput: standardOutput ?? Data(result.standardOutput.utf8),
            standardError: standardError ?? Data(result.standardError.utf8),
            progress: state.collector.progressData(),
            additionalEnvironment: environment.merging(state.command.environment) { _, value in value }
        )
    }

    private func waitForReaders(
        _ readers: CommandReaders,
        deadline: ContinuousClock.Instant?,
        cancellation: AxolotyCommandCancellation
    ) -> AxolotyCommandLifecycleOutcome? {
        let clock = ContinuousClock()
        let readerDeadline = min(
            deadline ?? clock.now.advanced(by: .seconds(Int64(readerShutdownGrace))),
            clock.now.advanced(by: .seconds(Int64(readerShutdownGrace)))
        )
        while !readers.wait(timeout: .now() + .milliseconds(20)) {
            if cancellation.isCancelled { return .cancelled }
            if clock.now >= readerDeadline { return .timedOut }
        }
        return nil
    }

    private func terminateAndReap(
        process: FoundationProcessHandle,
        processGroupID: Int32?,
        readers: CommandReaders
    ) -> TerminationResult {
        sendSignal(SIGTERM, to: process, processGroupID: processGroupID)
        let clock = ContinuousClock()
        let graceDeadline = clock.now.advanced(
            by: .nanoseconds(Int64(configuration.terminationGracePeriod * 1_000_000_000))
        )
        var readersFinished = false
        while clock.now < graceDeadline {
            readersFinished = readers.wait(timeout: .now())
            if !process.isRunning && readersFinished { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        readersFinished = readersFinished || readers.wait(timeout: .now())
        let needsKill = process.isRunning || !readersFinished
        if needsKill {
            sendSignal(SIGKILL, to: process, processGroupID: processGroupID)
        }
        process.waitUntilExit()
        if !readersFinished {
            // Once the process group is dead, let pipe readers reach EOF so
            // TERM-trap output already in the kernel pipe is retained. Only
            // cancel a reader that remains blocked on a detached descendant.
            readersFinished = readers.wait(timeout: .now() + readerShutdownGrace)
        }
        if !readersFinished {
            readers.cancel()
            _ = readers.wait(timeout: .now() + .milliseconds(250))
        }
        if let processGroupID {
            _ = axoloty_reap_process_group(processGroupID)
        }
        return TerminationResult(escalatedToKill: needsKill, readersFinished: readersFinished)
    }

    private func cancelledBeforeStart(
        command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext,
        startedAt: Date,
        deadline: Date?,
        collector: AxolotyCommandOutputCollector,
        artifact: AxolotyCommandArtifactStore.Artifact
    ) -> AxolotyCheckCommandResult {
        let result = Self.interruptedResult(
            outcome: .cancelled,
            context: context,
            startedAt: startedAt,
            deadline: deadline,
            collector: collector,
            artifact: artifact,
            escalatedToKill: false
        )
        artifactStore.finish(
            artifact,
            startedAt: startedAt,
            finishedAt: Date(),
            result: result,
            standardOutput: Data(result.standardOutput.utf8),
            standardError: Data(result.standardError.utf8),
            progress: collector.progressData(),
            additionalEnvironment: environment.merging(command.environment) { _, value in value }
        )
        return result
    }

    private static func interruptedResult(
        outcome: AxolotyCommandLifecycleOutcome,
        context: AxolotyCommandRunContext,
        startedAt: Date,
        deadline: Date?,
        collector: AxolotyCommandOutputCollector,
        artifact: AxolotyCommandArtifactStore.Artifact,
        escalatedToKill: Bool
    ) -> AxolotyCheckCommandResult {
        let finishedAt = Date()
        let lifecycle = AxolotyCommandLifecycle(
            outcome: outcome,
            node: context.node,
            stage: context.stage,
            elapsedSeconds: finishedAt.timeIntervalSince(startedAt),
            deadline: deadline.map { ISO8601DateFormatter().string(from: $0) },
            lastTest: collector.latestTest,
            artifactPath: artifact.directory.path,
            escalatedToKill: escalatedToKill
        )
        let summary = switch outcome {
        case .timedOut: "command timed out"
        case .cancelled: "command cancelled"
        }
        let diagnostic = "\(summary): node=\(context.node ?? "command") stage=\(context.stage) "
            + "deadline=\(lifecycle.deadline ?? "none") last-test=\(lifecycle.lastTest ?? "none") "
            + "artifacts=\(artifact.directory.path)\n"
        let standardError = String(decoding: collector.data(for: .standardError), as: UTF8.self) + diagnostic
        return AxolotyCheckCommandResult(
            exitCode: outcome == .timedOut ? 124 : 130,
            standardOutput: String(decoding: collector.data(for: .standardOutput), as: UTF8.self),
            standardError: standardError,
            lifecycle: lifecycle
        )
    }

    private func launchProcess(_ command: AxolotyCommandPlan) throws -> CommandProcessResources {
        _ = axoloty_enable_child_subreaper()
        let stdout = Pipe()
        let stderr = Pipe()
        let mergedEnvironment = environment.merging(command.environment) { _, value in value }
        let executable = resolveExecutable(command.executable, environment: mergedEnvironment)
        let arguments = [command.executable] + command.arguments
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let environmentEntries = mergedEnvironment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentEntries.map { strdup($0) }
        envp.append(nil)
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = axoloty_spawn_process(
            executable,
            &argv,
            &envp,
            stdout.fileHandleForReading.fileDescriptor,
            stderr.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stderr.fileHandleForWriting.fileDescriptor,
            &pid
        )
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        return CommandProcessResources(
            process: FoundationProcessHandle(processIdentifier: pid),
            stdout: stdout,
            stderr: stderr,
            processGroupID: pid
        )
    }

    private func startReaders(
        stdout: Pipe,
        stderr: Pipe,
        collector: AxolotyCommandOutputCollector
    ) -> CommandReaders {
        let stdoutReader = CommandPipeReader(
            handle: stdout.fileHandleForReading,
            stream: .standardOutput,
            collector: collector
        )
        let stderrReader = CommandPipeReader(
            handle: stderr.fileHandleForReading,
            stream: .standardError,
            collector: collector
        )
        let readers = CommandReaders(stdout: stdoutReader, stderr: stderrReader)
        readers.start()
        return readers
    }

    private func resolveExecutable(_ executable: String, environment: [String: String]) -> String {
        guard !executable.contains("/") else { return executable }
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return executable
    }

    private func sendSignal(_ signal: Int32, to process: FoundationProcessHandle, processGroupID: Int32?) {
        if let processGroupID, processGroupID > 1 {
            _ = kill(-processGroupID, signal)
            if process.processIdentifier != processGroupID {
                _ = kill(process.processIdentifier, signal)
            }
        } else if process.processIdentifier > 1 {
            let pid = process.processIdentifier
            _ = kill(pid, signal)
        }
    }

    private static func emitHeartbeat(
        context: AxolotyCommandRunContext,
        startedAt: Date,
        lastTest: String?,
        outputBytes: Int,
        collector: AxolotyCommandOutputCollector
    ) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let node = context.node ?? "command"
        let test = lastTest ?? "none"
        let heartbeat = String(
            format: "heartbeat node=%@ stage=%@ elapsed=%.1fs last-test=%@ output-bytes=%d\n",
            locale: Locale(identifier: "en_US_POSIX"),
            node,
            context.stage,
            elapsed,
            test,
            outputBytes
        )
        collector.emitProgress(heartbeat)
    }
}
// swiftlint:enable type_body_length file_length function_body_length function_parameter_count optional_data_string_conversion

private struct CommandProcessResources {
    let process: FoundationProcessHandle
    let stdout: Pipe
    let stderr: Pipe
    let processGroupID: Int32
}

private struct TerminationResult {
    let escalatedToKill: Bool
    let readersFinished: Bool
}

private struct CommandExecutionState {
    let process: FoundationProcessHandle
    let processGroupID: Int32?
    let readers: CommandReaders
    let deadline: Date?
    let clockDeadline: ContinuousClock.Instant?
    let cancellation: AxolotyCommandCancellation
    let collector: AxolotyCommandOutputCollector
    let command: AxolotyCommandPlan
    let context: AxolotyCommandRunContext
    let startedAt: Date
    let artifact: AxolotyCommandArtifactStore.Artifact
}

private final class CommandReaders: @unchecked Sendable {
    private let group = DispatchGroup()
    private let stdout: CommandPipeReader
    private let stderr: CommandPipeReader
    private let lock = NSLock()
    private var cancelled = false

    init(stdout: CommandPipeReader, stderr: CommandPipeReader) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() {
        DispatchQueue.global(qos: .utility).async(group: group, execute: stdout.read)
        DispatchQueue.global(qos: .utility).async(group: group, execute: stderr.read)
    }

    func wait(timeout: DispatchTime) -> Bool {
        group.wait(timeout: timeout) == .success
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        stdout.cancel()
        stderr.cancel()
    }
}

private final class CommandPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let descriptor: Int32
    private let cancellationPipe: Pipe
    private let cancellationReadDescriptor: Int32
    private let cancellationWriteDescriptor: Int32
    private let stream: AxolotyCommandOutputStream
    private let collector: AxolotyCommandOutputCollector
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    init(handle: FileHandle, stream: AxolotyCommandOutputStream, collector: AxolotyCommandOutputCollector) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        cancellationPipe = Pipe()
        cancellationReadDescriptor = cancellationPipe.fileHandleForReading.fileDescriptor
        cancellationWriteDescriptor = cancellationPipe.fileHandleForWriting.fileDescriptor
        self.stream = stream
        self.collector = collector
    }

    func read() {
        defer {
            lock.lock()
            finished = true
            handle.closeFile()
            cancellationPipe.fileHandleForReading.closeFile()
            cancellationPipe.fileHandleForWriting.closeFile()
            lock.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock()
            let shouldStop = cancelled
            lock.unlock()
            if shouldStop { break }

            var pollDescriptors = [
                pollfd(fd: descriptor, events: lifecyclePollIn | lifecyclePollHup | lifecyclePollErr, revents: 0),
                pollfd(fd: cancellationReadDescriptor, events: lifecyclePollIn, revents: 0),
            ]
            let ready = poll(&pollDescriptors, 2, 50)
            if ready <= 0 { continue }
            if pollDescriptors[1].revents != 0 { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Glibc)
                Glibc.read(descriptor, bytes.baseAddress, bytes.count)
                #else
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                #endif
            }
            if count > 0 {
                collector.append(Data(buffer[0..<Int(count)]), from: stream)
            } else if count == 0 || errno != EINTR {
                break
            }
        }
    }

    func cancel() {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { bytes in
            #if canImport(Glibc)
            Glibc.write(cancellationWriteDescriptor, bytes.baseAddress, 1)
            #else
            Darwin.write(cancellationWriteDescriptor, bytes.baseAddress, 1)
            #endif
        }
        lock.unlock()
    }
}

private final class FoundationProcessHandle: @unchecked Sendable {
    let processIdentifier: Int32
    private let lock = NSLock()
    private var status: Int32?

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if status != nil { return false }
        var childStatus: Int32 = 0
        let result = waitpid(processIdentifier, &childStatus, WNOHANG)
        if result == processIdentifier {
            status = childStatus
            return false
        }
        return result == 0
    }

    func waitUntilExit() {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil else { return }
        var childStatus: Int32 = 0
        _ = waitpid(processIdentifier, &childStatus, 0)
        status = childStatus
    }

    var terminationStatus: Int32 {
        waitUntilExit()
        lock.lock()
        defer { lock.unlock() }
        guard let status else { return 70 }
        return axoloty_process_exit_code(status)
    }
}
