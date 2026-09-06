// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("CommandOutputLineObserverTests")
struct CommandOutputLineObserverTests {
    private final class ObservedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(stream: AxolotyCommandOutputStream, line: String)] = []

        func append(_ stream: AxolotyCommandOutputStream, _ line: String) {
            lock.lock()
            lines.append((stream, line))
            lock.unlock()
        }

        var all: [(stream: AxolotyCommandOutputStream, line: String)] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private func makeCollector(
        observing observed: ObservedLines,
        streamedStreams: Set<AxolotyCommandOutputStream> = []
    ) -> AxolotyCommandOutputCollector {
        let collector = AxolotyCommandOutputCollector(
            streamOutput: { _, _ in },
            streamedStreams: streamedStreams
        )
        collector.setLineObserver { stream, line in
            observed.append(stream, line)
        }
        return collector
    }

    @Test
    func fragmentedPipeReadsProduceOneCompleteLogicalLine() throws {
        let observed = ObservedLines()
        let collector = makeCollector(observing: observed)
        collector.append(Data("[84/217] Compil".utf8), from: .standardOutput)
        collector.append(Data("ing Axoloty MQTT".utf8), from: .standardOutput)
        collector.append(Data("Client.swift\n".utf8), from: .standardOutput)
        let lines = observed.all
        #expect(lines.count == 1)
        #expect(lines.first?.line == "[84/217] Compiling Axoloty MQTTClient.swift")
        #expect(lines.first?.stream == .standardOutput)
    }

    @Test
    func streamsAreObservedIndependently() throws {
        let observed = ObservedLines()
        let collector = makeCollector(observing: observed)
        collector.append(Data("out-one\n".utf8), from: .standardOutput)
        collector.append(Data("err-one\n".utf8), from: .standardError)
        let lines = observed.all
        #expect(lines.count == 2)
        #expect(lines[0].stream == .standardOutput)
        #expect(lines[0].line == "out-one")
        #expect(lines[1].stream == .standardError)
        #expect(lines[1].line == "err-one")
    }

    @Test
    func finalUnterminatedLineIsObservedByFinishLines() throws {
        let observed = ObservedLines()
        let collector = makeCollector(observing: observed)
        collector.append(Data("terminated\n".utf8), from: .standardOutput)
        collector.append(Data("partial tail without newline".utf8), from: .standardOutput)
        collector.finishLines()
        let lines = observed.all
        #expect(lines.count == 2)
        #expect(lines.last?.line == "partial tail without newline")
    }

    @Test
    func rawCaptureIsPreservedRegardlessOfObserver() throws {
        let observed = ObservedLines()
        let collector = makeCollector(observing: observed)
        let payload = Data("[84/217] Compil".utf8)
        collector.append(payload, from: .standardOutput)
        collector.append(Data("ing Axoloty MQTTClient.swift\n".utf8), from: .standardOutput)
        let captured = String(decoding: collector.data(for: .standardOutput), as: UTF8.self)
        #expect(captured == "[84/217] Compiling Axoloty MQTTClient.swift\n")
    }

    @Test
    func emitProgressLockedRecordsPlainAndEmitsLive() throws {
        final class StreamRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var texts: [String] = []
            func append(_ text: String) {
                lock.lock()
                texts.append(text)
                lock.unlock()
            }
            var all: [String] {
                lock.lock()
                defer { lock.unlock() }
                return texts
            }
        }
        let recorder = StreamRecorder()
        let collector = AxolotyCommandOutputCollector(
            streamOutput: { _, text in recorder.append(text) },
            streamedStreams: []
        )
        collector.setLineObserver { _, _ in }
        collector.emitProgressLocked("\r\u{1B}[2Kstatus", plain: "status")
        #expect(recorder.all.count == 1)
        #expect(String(decoding: collector.progressData(), as: UTF8.self) == "status")
    }
}
