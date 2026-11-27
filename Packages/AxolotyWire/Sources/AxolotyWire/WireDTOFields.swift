// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Kind-checked field accessors shared by the borrowed wire DTOs.
//
// A borrowed DTO must reject a present field of the wrong kind rather than
// treating it as absent. The public typed accessors return `nil` for both
// cases, so a DTO that needs the distinction checks `fieldKind` first. The
// owned DTOs already validate every field shape; these helpers keep the
// borrowed and owned boundaries in agreement.

extension WireReader {
    /// Reads an optional object field.
    ///
    /// - Parameter key: The field to read.
    /// - Returns: The complete encoded object, or `nil` when the field is
    ///   absent or explicit `null`.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    func wireOptionalObject(_ key: StaticString) throws(WireDecodeError) -> ByteSlice? {
        guard try wireCheckOptional(key, expected: .object, name: "object") else { return nil }
        return readOptionalRaw(key)
    }

    /// Reads an optional array field.
    ///
    /// - Parameter key: The field to read.
    /// - Returns: The complete encoded array, or `nil` when the field is
    ///   absent or explicit `null`.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    func wireOptionalArray(_ key: StaticString) throws(WireDecodeError) -> ByteSlice? {
        guard try wireCheckOptional(key, expected: .array, name: "array") else { return nil }
        return readOptionalRaw(key)
    }

    /// Reads an optional object-or-array field.
    ///
    /// - Parameter key: The field to read.
    /// - Returns: The complete encoded value, or `nil` when the field is absent
    ///   or explicit `null`.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    func wireOptionalObjectOrArray(_ key: StaticString) throws(WireDecodeError) -> ByteSlice? {
        guard let kind = fieldKind(key), kind != .null else { return nil }
        guard kind == .object || kind == .array else {
            throw WireDecodeError(.typeMismatch(expected: "object or array"), field: key)
        }
        return readOptionalRaw(key)
    }

    /// Reads an optional string field.
    ///
    /// - Parameters:
    ///   - key: The field to read.
    ///   - rejectingNull: When `true`, an explicit `null` is a type mismatch
    ///     instead of an absent value.
    /// - Returns: The encoded string content, or `nil` when the field is
    ///   absent or accepted as null.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    func wireOptionalString(_ key: StaticString, rejectingNull: Bool = false) throws(WireDecodeError) -> ByteSlice? {
        guard try wireCheckOptional(key, expected: .string, name: "string", nullIsAbsent: !rejectingNull) else {
            return nil
        }
        return readString(key)
    }

    /// Reads an optional boolean field.
    ///
    /// - Parameters:
    ///   - key: The field to read.
    ///   - rejectingNull: When `true`, an explicit `null` is a type mismatch
    ///     instead of an absent value.
    /// - Returns: The boolean, or `nil` when the field is absent or accepted
    ///   as null.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    func wireOptionalBool(_ key: StaticString, rejectingNull: Bool = false) throws(WireDecodeError) -> Bool? {
        guard let kind = fieldKind(key) else { return nil }
        if kind == .null, !rejectingNull { return nil }
        guard kind == .trueValue || kind == .falseValue else {
            throw WireDecodeError(.typeMismatch(expected: "boolean"), field: key)
        }
        return readBool(key)
    }

    /// Reads an optional integer field.
    ///
    /// - Parameters:
    ///   - key: The field to read.
    ///   - rejectingNull: When `true`, an explicit `null` is a type mismatch
    ///     instead of an absent value.
    /// - Returns: The integer, or `nil` when the field is absent or accepted
    ///   as null.
    /// - Throws: ``WireDecodeError`` when the field is present but is not an
    ///   integer that fits `Int`.
    func wireOptionalInteger(_ key: StaticString, rejectingNull: Bool = false) throws(WireDecodeError) -> Int? {
        guard try wireCheckOptional(key, expected: .number, name: "integer", nullIsAbsent: !rejectingNull) else {
            return nil
        }
        guard let value = readInt(key) else {
            throw WireDecodeError(.invalidValue, field: key)
        }
        return value
    }

    /// Reads a required object field.
    ///
    /// - Parameter key: The field to read.
    /// - Returns: The complete encoded object.
    /// - Throws: ``WireDecodeError`` when the field is absent or is not an object.
    func wireRequiredObject(_ key: StaticString) throws(WireDecodeError) -> ByteSlice {
        guard let kind = fieldKind(key) else {
            throw WireDecodeError(.missingField, field: key)
        }
        guard kind == .object, let value = readOptionalRaw(key) else {
            throw WireDecodeError(.typeMismatch(expected: "object"), field: key)
        }
        return value
    }

    /// Reads a required array field.
    ///
    /// - Parameter key: The field to read.
    /// - Returns: The complete encoded array.
    /// - Throws: ``WireDecodeError`` when the field is absent or is not an array.
    func wireRequiredArray(_ key: StaticString) throws(WireDecodeError) -> ByteSlice {
        guard let kind = fieldKind(key) else {
            throw WireDecodeError(.missingField, field: key)
        }
        guard kind == .array, let value = readOptionalRaw(key) else {
            throw WireDecodeError(.typeMismatch(expected: "array"), field: key)
        }
        return value
    }

    /// Returns `true` when the field is present with the expected kind.
    ///
    /// - Parameters:
    ///   - key: The field to check.
    ///   - expected: The only accepted lexical kind.
    ///   - name: The description used in a type-mismatch error.
    ///   - nullIsAbsent: When `true`, explicit `null` yields `false` instead of
    ///     an error.
    /// - Returns: `true` when the value may be read with the expected accessor.
    /// - Throws: ``WireDecodeError`` when the field is present with another kind.
    private func wireCheckOptional(
        _ key: StaticString,
        expected: WireObjectFieldKind,
        name: StaticString,
        nullIsAbsent: Bool = true
    ) throws(WireDecodeError) -> Bool {
        guard let actual = fieldKind(key) else { return false }
        if actual == .null, nullIsAbsent { return false }
        guard actual == expected else {
            throw WireDecodeError(.typeMismatch(expected: name), field: key)
        }
        return true
    }
}
