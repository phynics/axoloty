// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import IkigaJSON

/// Helper methods for extracting nested JSON values from wire payloads as
/// `Data`, used by event snapshot initializers that need to preserve complex
/// fields (e.g. `ObjectFilter`, `ObjectJoinCondition`) in their encoded form
/// without coupling the snapshot to mutable class types.
enum WirePayloadExtractor {

    /// Extracts any non-null object or array JSON value at the given key as `Data`.
    static func nestedPayload(from payload: String, key: String) -> Data? {
        guard let root = try? JSONObject(data: Data(payload.utf8)),
              let value = root[key], value.null == nil else {
            return nil
        }
        return value.object?.data ?? value.array?.data
    }

    /// Extracts a JSON object (dictionary) at the given key as `Data`.
    static func nestedObjectPayload(from payload: String, key: String) -> Data? {
        guard let root = try? JSONObject(data: Data(payload.utf8)),
              let object = root[key]?.object else {
            return nil
        }
        return object.data
    }

    /// Extracts a JSON array at the given key as `[Data]`, one `Data` per
    /// element.
    static func nestedArrayPayload(from payload: String, key: String) -> [Data]? {
        guard let root = try? JSONObject(data: Data(payload.utf8)),
              let array = root[key]?.array else {
            return nil
        }
        let result = array.compactMap { value -> Data? in
            value.object?.data ?? value.array?.data
        }
        return result.isEmpty ? nil : result
    }
}
