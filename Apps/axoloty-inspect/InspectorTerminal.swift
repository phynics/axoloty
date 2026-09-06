// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Detects whether a file handle is connected to a terminal.
enum InspectorTerminal {
    /// Returns `true` when stdout is a TTY (interactive terminal).
    static var isStdoutTerminal: Bool {
        isatty(1) != 0
    }
}

/// Reads a single line from stdin, trimming the trailing newline.
enum InspectorPasswordReader {
    /// Reads one line from stdin and returns it without the line ending.
    ///
    /// Returns `nil` if stdin is empty or at EOF.
    static func readLineFromStdin() -> String? {
        guard let line = Swift.readLine(strippingNewline: true), !line.isEmpty else {
            return nil
        }
        return line
    }
}
