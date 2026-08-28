// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Resolves the repository version used by first-party tooling.
public enum AxolotyVersion {
    /// Reads an explicit process value or the checkout's root `VERSION` file.
    ///
    /// The source-path fallback is intentionally limited to first-party
    /// tooling. Published library consumers never need to discover a checkout
    /// version at runtime.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourcePath: String = #filePath
    ) -> String {
        if let value = environment["AXOLOTY_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let root = URL(fileURLWithPath: sourcePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if let value = try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "unavailable"
    }
}
