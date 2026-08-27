// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

extension JSONTokenizer {
    /// Scans one value and returns the parser failure without exposing a
    /// throwing boundary to callers.
    @usableFromInline
    mutating func scanValueResult() -> JSONParserError? {
        do {
            try scanValue()
            return nil
        } catch {
            return error
        }
    }
}
