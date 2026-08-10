// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

final class ToolingServiceOutputCapture {
    private let standardOutputPipe: Pipe
    private let standardErrorPipe: Pipe
    let standardOutput: FileHandle
    let standardError: FileHandle

    init() {
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        self.standardOutputPipe = standardOutputPipe
        self.standardErrorPipe = standardErrorPipe
        standardOutput = standardOutputPipe.fileHandleForWriting
        standardError = standardErrorPipe.fileHandleForWriting
    }

    func read() -> (standardOutput: String, standardError: String) {
        try? standardOutput.close()
        try? standardError.close()
        return (
            String(decoding: standardOutputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

func decodeServiceJSONObject(_ output: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}
