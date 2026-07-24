// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Helper methods for extracting nested JSON values from wire payloads as
/// `String`, used by event snapshot initializers that need to preserve complex
/// fields (e.g. `ObjectFilter`, `ObjectJoinCondition`) in their encoded form
/// without coupling the snapshot to mutable class types.
///
/// Uses `WireReader` for zero-allocation single-pass scanning instead of
/// `JSONObject(data:)` which allocates a full JSON tree.
enum WirePayloadExtractor {

    /// Extracts any non-null object or array JSON value at the given key as
    /// a raw JSON string.
    static func nestedPayload(from payload: String, key: StaticString) -> String? {
        var payload = payload
        return payload.withUTF8 { buf in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let slice = reader.readField(key) else { return nil }
            return sliceToString(slice)
        }
    }

    /// Extracts a JSON object (dictionary) at the given key as a raw JSON
    /// string.
    static func nestedObjectPayload(from payload: String, key: StaticString) -> String? {
        var payload = payload
        return payload.withUTF8 { buf in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let slice = reader.readField(key) else { return nil }
            guard slice.length > 0,
                  slice.byte(at: 0) == 0x7B else { return nil }
            return sliceToString(slice)
        }
    }

    /// Extracts a JSON array at the given key, returning one raw JSON string
    /// per element.
    static func nestedArrayPayload(from payload: String, key: StaticString) -> [String]? {
        var payload = payload
        return payload.withUTF8 { buf -> [String]? in
            guard let base = buf.baseAddress else { return nil }
            let reader = WireReader(bytes: base, length: buf.count)
            guard let slice = reader.readField(key) else { return nil }
            guard slice.length > 0,
                  slice.byte(at: 0) == 0x5B else { return nil }
            return parseArrayElements(slice)
        }
    }

    /// Converts a `ByteSlice` to a `String` by copying the bytes.
    private static func sliceToString(_ slice: ByteSlice) -> String {
        let buf = UnsafeBufferPointer(
            start: slice.pointer.assumingMemoryBound(to: UInt8.self),
            count: slice.length
        )
        return String(decoding: buf, as: UTF8.self)
    }

    /// Scans a JSON array byte slice and extracts each element as a string.
    private static func parseArrayElements(_ arraySlice: ByteSlice) -> [String]? {
        var elements: [String] = []
        var pos = 1
        let end = arraySlice.length - 1

        while pos < end {
            while pos < end {
                let b = arraySlice.byte(at: pos)!
                if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { break }
                pos += 1
            }
            guard pos < end else { break }

            let b = arraySlice.byte(at: pos)!
            if b == 0x7B || b == 0x5B {
                let open = b
                let close: UInt8 = (open == 0x7B) ? 0x7D : 0x5D
                var depth = 0
                let start = pos
                var inString = false
                while pos < end {
                    let c = arraySlice.byte(at: pos)!
                    if inString {
                        if c == 0x5C { pos += 2; continue }
                        if c == 0x22 { inString = false }
                    } else {
                        if c == 0x22 { inString = true }
                        else if c == open { depth += 1 }
                        else if c == close {
                            depth -= 1
                            if depth == 0 { pos += 1; break }
                        }
                    }
                    pos += 1
                }
                let elemBytes = arraySlice.subSlice(from: start, length: pos - start)
                elements.append(sliceToString(elemBytes))
            } else {
                while pos < end {
                    let c = arraySlice.byte(at: pos)!
                    if c == 0x2C { break }
                    pos += 1
                }
            }

            while pos < end {
                let c = arraySlice.byte(at: pos)!
                if c == 0x2C { pos += 1; break }
                if c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { break }
                pos += 1
            }
        }

        return elements.isEmpty ? nil : elements
    }
}
