// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

final class AxolotyCommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output: [AxolotyCommandOutputStream: Data] = [:]
    private var progress = Data()
    private var pendingLines: [AxolotyCommandOutputStream: String] = [:]
    private var latestStartedTest: String?
    private let streamOutput: @Sendable (AxolotyCommandOutputStream, String) -> Void
    private let streamedStreams: Set<AxolotyCommandOutputStream>
    private let streamLock = NSLock()
    private let observerLock = NSLock()
    private var lineObserver: (@Sendable (AxolotyCommandOutputStream, String) -> Void)?

    init(
        streamOutput: @escaping @Sendable (AxolotyCommandOutputStream, String) -> Void,
        streamedStreams: Set<AxolotyCommandOutputStream>
    ) {
        self.streamOutput = streamOutput
        self.streamedStreams = streamedStreams
    }

    /// Installs the complete-line observer used for progress parsing.
    ///
    /// The observer runs while the collector holds its stream lock, so it is
    /// serialized across both streams and preserves arrival order. Observers
    /// must only call `emitProgressLocked` for live output; the plain
    /// `emitProgress` entry point would deadlock.
    func setLineObserver(_ observer: (@Sendable (AxolotyCommandOutputStream, String) -> Void)?) {
        observerLock.lock()
        defer { observerLock.unlock() }
        lineObserver = observer
    }

    func append(_ data: Data, from stream: AxolotyCommandOutputStream) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        streamLock.lock()
        lock.lock()
        output[stream, default: Data()].append(data)
        let previous = pendingLines[stream, default: ""]
        let combined = previous + text
        let components = combined.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLines[stream] = components.last.map(String.init) ?? ""
        var completeLines: [String] = []
        for line in components.dropLast() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
            completeLines.append(candidate)
        }
        let shouldStream = streamedStreams.contains(stream)
        lock.unlock()

        if shouldStream {
            streamOutput(stream, text)
        }
        observerLock.lock()
        let observer = lineObserver
        observerLock.unlock()
        if let observer {
            for line in completeLines where !line.isEmpty {
                observer(stream, line)
            }
        }
        streamLock.unlock()
    }

    func emitProgress(_ text: String) {
        streamLock.lock()
        lock.lock()
        progress.append(Data(text.utf8))
        lock.unlock()
        streamOutput(.standardError, text)
        streamLock.unlock()
    }

    /// Emits progress while the caller already holds the stream lock.
    ///
    /// Only the complete-line observer path may call this method; it appends
    /// the plain text to the durable progress record and forwards the live
    /// text to the configured output sink.
    ///
    /// - Parameters:
    ///   - text: The live text, possibly with terminal control sequences.
    ///   - plain: The text recorded in durable progress artifacts, with any
    ///     terminal control sequences removed.
    func emitProgressLocked(_ text: String, plain: String) {
        lock.lock()
        progress.append(Data(plain.utf8))
        lock.unlock()
        streamOutput(.standardError, text)
    }

    func data(for stream: AxolotyCommandOutputStream) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return output[stream, default: Data()]
    }

    var latestTest: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestStartedTest
    }

    func diagnosticSnapshot() -> (lastTest: String?, outputBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let outputBytes = output.values.reduce(into: 0) { total, data in total += data.count }
        return (latestStartedTest, outputBytes)
    }

    func progressData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func finishLines() {
        streamLock.lock()
        var observedLines: [AxolotyCommandOutputStream: [String]] = [:]
        lock.lock()
        for (stream, line) in pendingLines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
            if !candidate.isEmpty {
                observedLines[stream, default: []].append(candidate)
            }
        }
        pendingLines.removeAll()
        lock.unlock()
        observerLock.lock()
        let observer = lineObserver
        observerLock.unlock()
        if let observer {
            for (stream, lines) in observedLines {
                for line in lines {
                    observer(stream, line)
                }
            }
        }
        streamLock.unlock()
    }
}
