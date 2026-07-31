// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A bounded duration parsed from CLI argument strings such as ``"10s"``,
/// ``"2m"``, or ``"1h"``.
///
/// Use ``InspectorDuration/unlimited`` to indicate no timeout. The parsed
/// ``value`` is a Swift ``Duration`` so it composes with the concurrency
/// deadline APIs.
public struct InspectorDuration: Equatable, Sendable {
    /// The parsed duration, or `nil` when unlimited.
    public let value: Duration?

    /// A sentinel indicating no time bound.
    public static let unlimited = InspectorDuration(value: nil)

    private static let maxSeconds: Int64 = 86_400

    /// Creates a duration from a parsed ``Duration``.
    public init(value: Duration?) {
        self.value = value
    }

    /// Creates a duration from a raw string.
    ///
    /// Supported formats:
    /// - `"<N>s"` — N seconds
    /// - `"<N>m"` — N minutes
    /// - `"<N>h"` — N hours
    /// - `"unlimited"` — no bound
    ///
    /// Returns `nil` for zero, negative, malformed, or unreasonably large
    /// values (> 24 hours).
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "unlimited" {
            self = .unlimited
            return
        }
        guard let (amount, unit) = Self.splitSuffix(trimmed) else {
            return nil
        }
        guard amount > 0 else {
            return nil
        }
        let seconds: Int64
        switch unit {
        case "s":
            seconds = Int64(amount)
        case "m":
            seconds = Int64(amount) * 60
        case "h":
            seconds = Int64(amount) * 3_600
        default:
            return nil
        }
        guard seconds > 0, seconds <= Self.maxSeconds else {
            return nil
        }
        self.value = .seconds(seconds)
    }

    private static func splitSuffix(_ s: String) -> (Int, String)? {
        guard let lastChar = s.last, lastChar.isLetter else {
            return nil
        }
        let unit = String(lastChar).lowercased()
        let numberPart = String(s.dropLast())
        guard let amount = Int(numberPart) else {
            return nil
        }
        return (amount, unit)
    }
}
