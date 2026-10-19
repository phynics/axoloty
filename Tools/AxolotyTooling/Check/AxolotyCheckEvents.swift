// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization

/// A stable lifecycle event emitted while a check plan executes.
public struct AxolotyCheckExecutionEvent: Codable, Equatable, Sendable {
    /// The event phase.
    public enum Kind: String, Codable, Equatable, Sendable {
        /// A plan began.
        case planStarted = "plan-start"
        /// A node began, immediately before resource acquisition.
        case nodeStarted = "node-start"
        /// A node reached its expected duration.
        case nodeOverrun = "node-overrun"
        /// A node completed.
        case nodeCompleted = "node-completion"
        /// A plan reached its expected duration.
        case planOverrun = "plan-overrun"
        /// A plan completed.
        case planCompleted = "plan-completion"
    }

    /// Event phase.
    public let kind: Kind
    /// Node identifier for node events.
    public let node: String?
    /// Ordered prerequisites for a node event.
    public let dependencies: [String]?
    /// Scheduling lane declared for a node.
    public let lane: String?
    /// Process/resource isolation declared for a node.
    public let isolation: AxolotyTestIsolation?
    /// Explicit graph-level concurrency permission.
    public let parallelSafe: Bool?
    /// Resource claims declared for a node.
    public let resources: [String]?
    /// Shared, read-only resource claims declared for a node.
    public let sharedResources: [String]?
    /// Effective command timeout in seconds when known.
    public let timeoutSeconds: TimeInterval?
    /// Compilation time reported by SwiftPM when available.
    public let compilationSeconds: TimeInterval?
    /// Test case time reported by Swift Testing when available.
    public let testSeconds: TimeInterval?
    /// Effective node concurrency budget at plan start.
    public let concurrencyLimit: Int?
    /// Completion status when known.
    public let status: AxolotyCheckStatus?
    /// Subprocess exit status when known.
    public let exitCode: Int32?
    /// Whether the subprocess timed out.
    public let timedOut: Bool?
    /// The first prerequisite that prevented a dependent node from running.
    public let blockingDependency: String?
    /// Elapsed wall-clock seconds when known.
    public let elapsedSeconds: TimeInterval?
    /// Configured warning threshold when present.
    public let expectedDurationSeconds: TimeInterval?
    /// Time spent waiting for resource leases when known.
    public let resourceLeaseWaitSeconds: TimeInterval?
    /// Last observed Swift test when present.
    public let lastTest: String?
    /// Total subprocess output bytes when known.
    public let outputBytes: Int?
    /// Command artifact directory when present.
    public let artifactPath: String?

    /// Creates an execution event.
    public init(
        kind: Kind,
        node: String? = nil,
        dependencies: [String]? = nil,
        lane: String? = nil,
        isolation: AxolotyTestIsolation? = nil,
        parallelSafe: Bool? = nil,
        resources: [String]? = nil,
        sharedResources: [String]? = nil,
        timeoutSeconds: TimeInterval? = nil,
        compilationSeconds: TimeInterval? = nil,
        testSeconds: TimeInterval? = nil,
        concurrencyLimit: Int? = nil,
        status: AxolotyCheckStatus? = nil,
        exitCode: Int32? = nil,
        timedOut: Bool? = nil,
        blockingDependency: String? = nil,
        elapsedSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil,
        resourceLeaseWaitSeconds: TimeInterval? = nil,
        lastTest: String? = nil,
        outputBytes: Int? = nil,
        artifactPath: String? = nil
    ) {
        self.kind = kind
        self.node = node
        self.dependencies = dependencies
        self.lane = lane
        self.isolation = isolation
        self.parallelSafe = parallelSafe
        self.resources = resources
        self.sharedResources = sharedResources
        self.timeoutSeconds = timeoutSeconds
        self.compilationSeconds = compilationSeconds
        self.testSeconds = testSeconds
        self.concurrencyLimit = concurrencyLimit
        self.status = status
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.blockingDependency = blockingDependency
        self.elapsedSeconds = elapsedSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
        self.resourceLeaseWaitSeconds = resourceLeaseWaitSeconds
        self.lastTest = lastTest
        self.outputBytes = outputBytes
        self.artifactPath = artifactPath
    }

    func diagnosticLine() -> String {
        var fields = ["[axoloty]", "event=\(kind.rawValue)"]
        if let node { fields.append("node=\(node)") }
        if let dependencies { fields.append("depends=\(dependencies.isEmpty ? "-" : dependencies.joined(separator: ","))") }
        if let lane { fields.append("lane=\(lane)") }
        if let isolation { fields.append("isolation=\(isolation.rawValue)") }
        if let parallelSafe { fields.append("parallel-safe=\(parallelSafe)") }
        if let resources { fields.append("resources=\(resources.isEmpty ? "-" : resources.joined(separator: ","))") }
        if let sharedResources { fields.append("shared-resources=\(sharedResources.isEmpty ? "-" : sharedResources.joined(separator: ","))") }
        if let timeoutSeconds { fields.append(String(format: "timeout=%.3fs", locale: Locale(identifier: "en_US_POSIX"), timeoutSeconds)) }
        if let compilationSeconds { fields.append(String(format: "compile=%.3fs", locale: Locale(identifier: "en_US_POSIX"), compilationSeconds)) }
        if let testSeconds { fields.append(String(format: "test-time=%.3fs", locale: Locale(identifier: "en_US_POSIX"), testSeconds)) }
        if let concurrencyLimit { fields.append("concurrency=\(concurrencyLimit)") }
        if let status { fields.append("status=\(status.rawValue)") }
        if let exitCode { fields.append("exit-code=\(exitCode)") }
        if let timedOut { fields.append("timed-out=\(timedOut)") }
        if let blockingDependency { fields.append("blocked-by=\(blockingDependency)") }
        if let elapsedSeconds { fields.append(String(format: "elapsed=%.3fs", locale: Locale(identifier: "en_US_POSIX"), elapsedSeconds)) }
        if let expectedDurationSeconds { fields.append(String(format: "expected=%.3fs", locale: Locale(identifier: "en_US_POSIX"), expectedDurationSeconds)) }
        if let resourceLeaseWaitSeconds { fields.append(String(format: "lease-wait=%.3fs", locale: Locale(identifier: "en_US_POSIX"), resourceLeaseWaitSeconds)) }
        if let lastTest { fields.append("last-test=\(lastTest)") }
        if let outputBytes { fields.append("output-bytes=\(outputBytes)") }
        if let artifactPath { fields.append("artifact=\(artifactPath)") }
        return fields.joined(separator: " ") + "\n"
    }
}

protocol AxolotyOverrunCancellation: Sendable {
    func cancel()
}

protocol AxolotyOverrunScheduling: Sendable {
    func schedule(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> any AxolotyOverrunCancellation
}

// @unchecked: GCD does not mark dispatch sources Sendable; the timer is exclusively owned by the cancellation state.
private struct DispatchTimer: @unchecked Sendable {
    let source: DispatchSourceTimer
}

// @unchecked: the dispatch timer is exclusively transferred through this mutex.
private final class DispatchOverrunCancellation: AxolotyOverrunCancellation, @unchecked Sendable {
    private let source: Mutex<DispatchTimer?>

    init(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        self.source = Mutex(DispatchTimer(source: source))
        source.setEventHandler { [weak self] in self?.fire(action) }
        source.schedule(deadline: .now() + max(0, seconds), leeway: .milliseconds(10))
        source.resume()
    }

    func cancel() {
        let source = self.source.withLock { source -> DispatchSourceTimer? in
            defer { source = nil }
            return source?.source
        }
        source?.cancel()
    }

    private func fire(_ action: @escaping @Sendable () -> Void) {
        guard let source = source.withLock({ source -> DispatchSourceTimer? in
            defer { source = nil }
            return source?.source
        }) else { return }
        source.cancel()
        action()
    }
}

struct DispatchOverrunScheduler: AxolotyOverrunScheduling {
    func schedule(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> any AxolotyOverrunCancellation {
        DispatchOverrunCancellation(seconds: seconds, action: action)
    }
}
