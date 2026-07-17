// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Helper methods for extracting nested JSON values from wire payloads as
/// `Data`, used by event snapshot initializers that need to preserve complex
/// fields (e.g. `ObjectFilter`, `ObjectJoinCondition`) in their encoded form
/// without coupling the snapshot to mutable class types.
enum WirePayloadExtractor {

    /// Extracts any non-null JSON value at the given key as `Data`.
    ///
    /// Works for both JSON objects and JSON arrays. Returns `nil` when the key
    /// is absent, the value is `null`, or the value cannot be serialized.
    static func nestedPayload(from payload: String, key: String) -> Data? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root[key],
              !(value is NSNull),
              JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    /// Extracts a JSON object (dictionary) at the given key as `Data`.
    ///
    /// Returns `nil` for arrays, `null`, or missing values.
    static func nestedObjectPayload(from payload: String, key: String) -> Data? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root[key],
              let object = value as? [String: Any] else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Extracts a JSON array at the given key as `[Data]`, one `Data` per
    /// element.
    ///
    /// Returns `nil` for single objects, `null`, or missing values.
    static func nestedArrayPayload(from payload: String, key: String) -> [Data]? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root[key] as? [Any] else {
            return nil
        }
        let result = array.compactMap { element -> Data? in
            guard JSONSerialization.isValidJSONObject(element) else { return nil }
            return try? JSONSerialization.data(withJSONObject: element)
        }
        return result.isEmpty ? nil : result
    }
}
