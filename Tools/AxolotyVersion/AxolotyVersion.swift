// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Resolves the repository version used by first-party tooling.
public enum AxolotyVersion {
    /// This file's own location, captured where it is written rather than at a
    /// call site. A `#filePath` default argument expands in the *caller's*
    /// file, so anchoring here keeps resolution independent of how deeply any
    /// calling file happens to sit.
    private static let resolverPath = #filePath

    /// Reads an explicit process value or the checkout's root `VERSION` file.
    ///
    /// The source-path fallback is intentionally limited to first-party
    /// tooling. Published library consumers never need to discover a checkout
    /// version at runtime. Pass `sourcePath` to resolve from another location.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourcePath: String? = nil
    ) -> String {
        if let value = environment["AXOLOTY_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return checkoutVersion(near: sourcePath ?? resolverPath) ?? "unavailable"
    }

    /// Walks up from `sourcePath` to the first directory holding a `VERSION`
    /// file. Searching instead of counting directories means moving a source
    /// file cannot silently degrade the reported version.
    private static func checkoutVersion(near sourcePath: String) -> String? {
        var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent("VERSION")
            if let value = try? String(contentsOf: candidate, encoding: .utf8) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}
