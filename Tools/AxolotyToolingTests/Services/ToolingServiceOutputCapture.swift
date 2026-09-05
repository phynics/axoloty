// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

final class ConcurrentPipeCapture: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var captured = Data()

        func store(_ data: Data) {
            lock.lock()
            captured = data
            lock.unlock()
        }

        func output() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return String(bytes: captured, encoding: .utf8)
        }
    }

    private let pipe = Pipe()
    private let completion = DispatchGroup()
    private let state = State()

    var writer: FileHandle { pipe.fileHandleForWriting }

    init() {
        let reader = pipe.fileHandleForReading
        let completion = completion
        let state = state
        completion.enter()
        DispatchQueue.global(qos: .utility).async {
            state.store(reader.readDataToEndOfFile())
            completion.leave()
        }
    }

    func closeWriter() {
        try? writer.close()
    }

    func output(waitUntil deadline: DispatchTime) -> String? {
        guard completion.wait(timeout: deadline) == .success else { return nil }
        return state.output()
    }
}

final class ToolingServiceOutputCapture {
    private let standardOutputCapture: ConcurrentPipeCapture
    private let standardErrorCapture: ConcurrentPipeCapture
    let standardOutput: FileHandle
    let standardError: FileHandle

    init() {
        let standardOutputCapture = ConcurrentPipeCapture()
        let standardErrorCapture = ConcurrentPipeCapture()
        self.standardOutputCapture = standardOutputCapture
        self.standardErrorCapture = standardErrorCapture
        standardOutput = standardOutputCapture.writer
        standardError = standardErrorCapture.writer
    }

    func read() -> (standardOutput: String, standardError: String) {
        standardOutputCapture.closeWriter()
        standardErrorCapture.closeWriter()
        let deadline = DispatchTime.now() + .seconds(2)
        let standardOutput = standardOutputCapture.output(waitUntil: deadline)
        let standardError = standardErrorCapture.output(waitUntil: deadline)
        if standardOutput == nil || standardError == nil {
            Issue.record("Timed out draining tooling service output")
        }
        return (standardOutput ?? "", standardError ?? "")
    }
}

func decodeServiceJSONObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

@Test
func serviceOutputCaptureDrainsLargeWritesBeforeRead() {
    let capture = ToolingServiceOutputCapture()
    let standardOutput = String(repeating: "o", count: 1_048_576)
    let standardError = String(repeating: "e", count: 1_048_576)

    capture.standardOutput.write(Data(standardOutput.utf8))
    capture.standardError.write(Data(standardError.utf8))
    let captured = capture.read()

    #expect(captured.standardOutput == standardOutput)
    #expect(captured.standardError == standardError)
}
