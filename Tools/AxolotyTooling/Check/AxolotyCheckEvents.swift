// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
    /// Completion status when known.
    public let status: AxolotyCheckStatus?
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
        status: AxolotyCheckStatus? = nil,
        elapsedSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil,
        resourceLeaseWaitSeconds: TimeInterval? = nil,
        lastTest: String? = nil,
        outputBytes: Int? = nil,
        artifactPath: String? = nil
    ) {
        self.kind = kind
        self.node = node
        self.status = status
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
        if let status { fields.append("status=\(status.rawValue)") }
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

private final class DispatchOverrunCancellation: AxolotyOverrunCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    init(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        self.source = source
        source.setEventHandler { [weak self] in self?.fire(action) }
        source.schedule(deadline: .now() + max(0, seconds), leeway: .milliseconds(10))
        source.resume()
    }

    func cancel() {
        lock.lock()
        let source = source
        self.source = nil
        lock.unlock()
        source?.cancel()
    }

    private func fire(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard let source else {
            lock.unlock()
            return
        }
        self.source = nil
        lock.unlock()
        source.cancel()
        action()
    }
}

struct DispatchOverrunScheduler: AxolotyOverrunScheduling {
    func schedule(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> any AxolotyOverrunCancellation {
        DispatchOverrunCancellation(seconds: seconds, action: action)
    }
}
