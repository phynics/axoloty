// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization

final class AxolotyCommandOutputCollector: Sendable {
    private struct State: Sendable {
        var output: [AxolotyCommandOutputStream: Data] = [:]
        var progress = Data()
        var pendingLines: [AxolotyCommandOutputStream: String] = [:]
        var latestStartedTest: String?
    }
    private let state = Mutex(State())
    private let streamOutput: @Sendable (AxolotyCommandOutputStream, String) -> Void
    private let streamedStreams: Set<AxolotyCommandOutputStream>
    private let streamLock = Mutex(())
    private let lineObserver = Mutex<(@Sendable (AxolotyCommandOutputStream, String) -> Void)?>(nil)

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
        lineObserver.withLock { $0 = observer }
    }

    func append(_ data: Data, from stream: AxolotyCommandOutputStream) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        streamLock.withLock { _ in
            let completeLines = state.withLock { state -> [String] in
                state.output[stream, default: Data()].append(data)
                let previous = state.pendingLines[stream, default: ""]
                let combined = previous + text
                let components = combined.split(separator: "\n", omittingEmptySubsequences: false)
                state.pendingLines[stream] = components.last.map(String.init) ?? ""
                var completeLines: [String] = []
                for line in components.dropLast() {
                    let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.contains("◇ Test "), candidate.contains(" started") {
                        state.latestStartedTest = candidate
                    }
                    completeLines.append(candidate)
                }
                return completeLines
            }
            let shouldStream = streamedStreams.contains(stream)
            if shouldStream {
                streamOutput(stream, text)
            }
            let observer = lineObserver.withLock { $0 }
            if let observer {
                for line in completeLines where !line.isEmpty {
                    observer(stream, line)
                }
            }
        }
    }

    func emitProgress(_ text: String) {
        streamLock.withLock { _ in
            state.withLock { $0.progress.append(Data(text.utf8)) }
            streamOutput(.standardError, text)
        }
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
        state.withLock { $0.progress.append(Data(plain.utf8)) }
        streamOutput(.standardError, text)
    }

    func data(for stream: AxolotyCommandOutputStream) -> Data {
        state.withLock { $0.output[stream, default: Data()] }
    }

    var latestTest: String? {
        state.withLock { $0.latestStartedTest }
    }

    func diagnosticSnapshot() -> (lastTest: String?, outputBytes: Int) {
        state.withLock { state in
            let outputBytes = state.output.values.reduce(into: 0) { total, data in total += data.count }
            return (state.latestStartedTest, outputBytes)
        }
    }

    func progressData() -> Data {
        state.withLock { $0.progress }
    }

    func finishLines() {
        streamLock.withLock { _ in
            let observedLines = state.withLock { state -> [AxolotyCommandOutputStream: [String]] in
                var observedLines: [AxolotyCommandOutputStream: [String]] = [:]
                for (stream, line) in state.pendingLines {
                    let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.contains("◇ Test "), candidate.contains(" started") {
                        state.latestStartedTest = candidate
                    }
                    if !candidate.isEmpty {
                        observedLines[stream, default: []].append(candidate)
                    }
                }
                state.pendingLines.removeAll()
                return observedLines
            }
            let observer = lineObserver.withLock { $0 }
            if let observer {
                for (stream, lines) in observedLines {
                    for line in lines {
                        observer(stream, line)
                    }
                }
            }
        }
    }
}
