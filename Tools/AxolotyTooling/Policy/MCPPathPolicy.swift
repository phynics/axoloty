// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Validates and preserves the endpoint path shared by MCP entry points.
public enum MCPPathPolicy {
    /// Validates an MCP HTTP endpoint path without changing its spelling.
    ///
    /// - Parameter path: The configured endpoint path.
    /// - Returns: The unchanged path when valid, or the same user-facing
    ///   ``AxolotyServeError/invalidPath(_:)`` used by managed serving.
    public static func validate(_ path: String) -> Result<String, AxolotyServeError> {
        guard !path.isEmpty, path.hasPrefix("/") else {
            return .failure(.invalidPath(path))
        }
        return .success(path)
    }
}
