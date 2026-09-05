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

    init(
        streamOutput: @escaping @Sendable (AxolotyCommandOutputStream, String) -> Void,
        streamedStreams: Set<AxolotyCommandOutputStream>
    ) {
        self.streamOutput = streamOutput
        self.streamedStreams = streamedStreams
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
        for line in components.dropLast() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
        }
        let shouldStream = streamedStreams.contains(stream)
        lock.unlock()

        if shouldStream {
            streamOutput(stream, text)
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
        lock.lock()
        defer { lock.unlock() }
        for line in pendingLines.values {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
        }
        pendingLines.removeAll()
    }
}
