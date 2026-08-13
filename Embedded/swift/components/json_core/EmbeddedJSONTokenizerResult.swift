// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

extension JSONTokenizer {
    /// Scans one value without exposing a thrown error across the Embedded
    /// Swift module boundary.
    public mutating func scanValueResult() -> JSONParserError? {
        do {
            try scanValue()
            return nil
        } catch {
            return error
        }
    }
}
