// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

@usableFromInline
struct DynamicFieldDescriptor: Equatable, Sendable {
    var keyStart: Int = 0
    var keyLength: Int = 0
    var valueStart: Int = 0
    var valueLength: Int = 0
}

/// A synchronous borrowed field view into a dynamic object.
public struct ObjectFields: ~Copyable {
    @usableFromInline let bytes: UnsafeRawPointer
    @usableFromInline let length: Int
    @usableFromInline let descriptors: UnsafeRawPointer
    @usableFromInline let descriptorCount: Int

    @usableFromInline init(bytes: UnsafeRawPointer, length: Int, descriptors: UnsafeRawPointer, descriptorCount: Int) {
        self.bytes = bytes; self.length = length; self.descriptors = descriptors; self.descriptorCount = descriptorCount
    }

    /// Borrows a field's value only for the duration of `body`.
    public borrowing func withValue(for key: StaticString, _ body: (borrowing JSONValueView) -> Void) -> Bool {
        let descriptorBuffer = descriptors.assumingMemoryBound(to: DynamicFieldDescriptor.self)
        for index in 0..<descriptorCount {
            let descriptor = descriptorBuffer[index]
            let keySlice = ByteSlice(bytes: bytes.advanced(by: descriptor.keyStart).assumingMemoryBound(to: UInt8.self), length: descriptor.keyLength)
            if keySlice.semanticEquals(key) {
                let value = ByteSlice(bytes: bytes.advanced(by: descriptor.valueStart).assumingMemoryBound(to: UInt8.self), length: descriptor.valueLength)
                body(JSONValueView(raw: value)); return true
            }
        }
        return false
    }

    /// Borrows a field selected by an encoded key slice for the duration of `body`.
    public borrowing func withValue(for key: ByteSlice, _ body: (borrowing JSONValueView) -> Void) -> Bool {
        let descriptorBuffer = descriptors.assumingMemoryBound(to: DynamicFieldDescriptor.self)
        for index in 0..<descriptorCount {
            let descriptor = descriptorBuffer[index]
            let keySlice = ByteSlice(bytes: bytes.advanced(by: descriptor.keyStart).assumingMemoryBound(to: UInt8.self), length: descriptor.keyLength)
            if keySlice.semanticEquals(key) {
                let value = ByteSlice(bytes: bytes.advanced(by: descriptor.valueStart).assumingMemoryBound(to: UInt8.self), length: descriptor.valueLength)
                body(JSONValueView(raw: value)); return true
            }
        }
        return false
    }

    /// Returns an owned value snapshot that remains valid after the object changes.
    ///
    /// A missing key returns `nil`. A present value that cannot fit or is not
    /// valid JSON throws its structured ``ObjectError`` instead of appearing
    /// absent.
    public borrowing func snapshot<let snapshotCapacity: Int>(for key: StaticString) throws(ObjectError) -> OwnedJSONValue<snapshotCapacity>? {
        var result: OwnedJSONValue<snapshotCapacity>?
        var failure: ObjectError?
        let found = withValue(for: key) { value in
            do throws(ObjectError) {
                result = try OwnedJSONValue<snapshotCapacity>(copying: value)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return found ? result : nil
    }

    /// Reports whether a field is absent, null, or present without returning a borrowed view.
    public borrowing func presence(for key: StaticString) -> Presence<JSONValueKind> {
        var kind: JSONValueKind?
        _ = withValue(for: key) { kind = $0.kind }
        guard let kind else { return .missing }
        return kind == .null ? .null : .value(kind)
    }

    /// Creates a bounded decoder whose borrow ends with `body`.
    public borrowing func withDecoder<R>(_ body: (borrowing ObjectFieldDecoder) throws -> R) rethrows -> R {
        try body(ObjectFieldDecoder(bytes: bytes, length: length))
    }

    /// Decodes a typed schema without opening an untyped throwing closure.
    public borrowing func decode<Schema: ObjectSchema>(
        _ type: Schema.Type
    ) throws(ObjectDecodingError) -> Schema {
        try Schema(decoding: ObjectFieldDecoder(bytes: bytes, length: length))
    }
}

/// A bounded dynamic JSON object with inline raw bytes and field descriptors.
public struct BoundedDynamicObject<let byteCapacity: Int, let fieldCapacity: Int>: ~Copyable, Sendable {
    private var raw: InlineArray<byteCapacity, UInt8>
    private var descriptors: InlineArray<fieldCapacity, DynamicFieldDescriptor>
    private var rawLength: Int
    private var descriptorCount: Int

    @usableFromInline
    init(empty: Void = ()) {
        raw = InlineArray(repeating: 0)
        raw[0] = 123; raw[1] = 125
        descriptors = InlineArray(repeating: DynamicFieldDescriptor())
        rawLength = 2
        descriptorCount = 0
    }

    /// Decodes and owns one complete JSON object in the inline arena.
    public init(decoding bytes: ByteSlice) throws(ObjectError) {
        guard bytes.length <= byteCapacity else { throw ObjectError(.capacityExceeded, byteOffset: bytes.length) }
        var localRaw = InlineArray<byteCapacity, UInt8>(repeating: 0)
        var localDescriptors = InlineArray<fieldCapacity, DynamicFieldDescriptor>(repeating: DynamicFieldDescriptor())
        let localRawLength = bytes.length
        var localDescriptorCount = 0
        var failure: ObjectError?
        bytes.withBytes { (pointer: UnsafeRawPointer, count: Int) -> Void in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            do throws(WireDecodeError) { try reader.validate() } catch { failure = objectError(error); return }
            for index in 0..<count { localRaw[index] = pointer.load(fromByteOffset: index, as: UInt8.self) }
            do throws(ObjectError) { try fillDescriptors(reader, descriptors: &localDescriptors, count: &localDescriptorCount) }
            catch { failure = error }
        }
        if let failure { throw failure }
        self.raw = localRaw
        self.descriptors = localDescriptors
        self.rawLength = localRawLength
        self.descriptorCount = localDescriptorCount
    }

    /// Decodes an object from a caller-owned byte buffer.
    public init(decoding bytes: UnsafePointer<UInt8>, length: Int) throws(ObjectError) {
        try self.init(decoding: ByteSlice(bytes: bytes, length: length))
    }

    /// Borrows all fields synchronously for the duration of `body`.
    public borrowing func withFields<R>(_ body: (borrowing ObjectFields) throws -> R) rethrows -> R {
        try withUnsafeBytesOfRaw { pointer in
            try withUnsafeBytes(of: descriptors) { descriptorBytes in
                try body(ObjectFields(
                    bytes: pointer,
                    length: rawLength,
                    descriptors: descriptorBytes.baseAddress!,
                    descriptorCount: descriptorCount
                ))
            }
        }
    }

    /// Decodes a typed schema directly from the owned object fields.
    public borrowing func decode<Schema: ObjectSchema>(
        _ type: Schema.Type
    ) throws(ObjectDecodingError) -> Schema {
        var result: Schema?
        var failure: ObjectDecodingError?
        withUnsafeBytesOfRaw { pointer in
            withUnsafeBytes(of: descriptors) { descriptorBytes in
                let fields = ObjectFields(
                    bytes: pointer,
                    length: rawLength,
                    descriptors: descriptorBytes.baseAddress!,
                    descriptorCount: descriptorCount
                )
                do throws(ObjectDecodingError) {
                    result = try fields.decode(type)
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw failure }
        return result!
    }

    /// Compares the exact encoded bytes against a static UTF-8 literal.
    public borrowing func encodedEquals(_ value: StaticString) -> Bool {
        withUnsafeBytesOfRaw { pointer in
            ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: rawLength).equals(value)
        }
    }

    /// Borrows the complete encoded object for the duration of `body`.
    ///
    /// - Parameter body: A synchronous operation receiving the borrowed bytes.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `body`.
    public borrowing func withEncodedBytes<R>(_ body: (borrowing ByteSlice) throws -> R) rethrows -> R {
        try withUnsafeBytesOfRaw { pointer in
            try body(ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: rawLength))
        }
    }

    /// Decodes the current envelope snapshot, preventing a cached envelope from
    /// becoming a second mutable source of truth after an edit.
    public borrowing func withEnvelope<let nameCapacity: Int, let externalIDCapacity: Int, R>(
        _ body: (ObjectEnvelope<nameCapacity, externalIDCapacity>) -> R
    ) throws(ObjectError) -> R {
        var result: R?
        var failure: ObjectError?
        withUnsafeBytesOfRaw { pointer in
            let bytes = ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: rawLength)
            do throws(ObjectError) { result = body(try ObjectEnvelope<nameCapacity, externalIDCapacity>(decoding: bytes)) }
            catch { failure = error }
        }
        if let failure { throw failure }
        return result!
    }

    /// Applies a fixed edit plan atomically. Any failure leaves this object unchanged.
    @discardableResult
    public mutating func edit<R>(_ body: (inout ObjectEditor<byteCapacity>) throws -> R) throws -> R {
        var editor = withUnsafeBytesOfRaw { pointer in
            ObjectEditor<byteCapacity>(source: ByteSlice(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: rawLength))
        }
        let result = try body(&editor)
        try editor.commit(into: &self)
        return result
    }

    private func withUnsafeBytesOfRaw<R>(_ body: (UnsafeRawPointer) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: raw) { buffer in try body(buffer.baseAddress!) }
    }

    fileprivate mutating func replaceFromEditor<let editorCapacity: Int>(_ editor: ObjectEditor<editorCapacity>) throws(ObjectError) {
        guard editor.outputLength <= byteCapacity else { throw ObjectError(.capacityExceeded, byteOffset: editor.outputLength) }
        var nextRaw = InlineArray<byteCapacity, UInt8>(repeating: 0)
        var nextDescriptors = InlineArray<fieldCapacity, DynamicFieldDescriptor>(repeating: DynamicFieldDescriptor())
        var nextLength = 0
        var nextCount = 0
        var failure: ObjectError?
        withUnsafeBytes(of: editor.output) { (buffer: UnsafeRawBufferPointer) -> Void in
            nextLength = editor.outputLength
            for index in 0..<nextLength { nextRaw[index] = buffer[index] }
            let reader = WireReader(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), length: nextLength)
            do throws(WireDecodeError) { try reader.validate() } catch { failure = objectError(error); return }
            do throws(ObjectError) { try fillDescriptors(reader, descriptors: &nextDescriptors, count: &nextCount) }
            catch { failure = error }
        }
        if let failure { throw failure }
        raw = nextRaw
        descriptors = nextDescriptors
        rawLength = nextLength
        descriptorCount = nextCount
    }

    @usableFromInline
    init(committing editor: inout ObjectEditor<byteCapacity>) throws(ObjectError) {
        self.init(empty: ())
        try editor.commit(into: &self)
    }
}

@usableFromInline
struct EditOperation {
    // Matches ObjectType's documented bounded UTF-8 key capacity.
    var key: InlineArray<128, UInt8> = InlineArray(repeating: 0)
    var keyLength: Int = 0
    var valueStart: Int = 0
    var valueLength: Int = 0
    var kind: UInt8 = 0 // 0 = set, 1 = remove
}

/// A bounded, two-phase edit plan for a dynamic object.
public struct ObjectEditor<let byteCapacity: Int> {
    @usableFromInline var source: InlineArray<byteCapacity, UInt8>
    @usableFromInline var sourceLength: Int
    @usableFromInline var values: InlineArray<byteCapacity, UInt8>
    @usableFromInline var valueLength: Int
    // The wire tokenizer's authoritative indexed-field maximum.
    @usableFromInline var operations: InlineArray<24, EditOperation>
    @usableFromInline var operationCount: Int
    @usableFromInline var output: InlineArray<byteCapacity, UInt8>
    @usableFromInline var outputLength: Int

    @usableFromInline init(source bytes: ByteSlice) {
        source = InlineArray(repeating: 0); sourceLength = bytes.length
        values = InlineArray(repeating: 0); valueLength = 0
        operations = InlineArray(repeating: EditOperation()); operationCount = 0
        output = InlineArray(repeating: 0); outputLength = 0
        for index in 0..<bytes.length { source[index] = bytes.byte(at: index)! }
    }

    @usableFromInline init(empty: Void = ()) {
        source = InlineArray(repeating: 0); sourceLength = 2
        source[0] = 123; source[1] = 125
        values = InlineArray(repeating: 0); valueLength = 0
        operations = InlineArray(repeating: EditOperation()); operationCount = 0
        output = InlineArray(repeating: 0); outputLength = 0
    }

    /// Sets a field to a borrowed raw JSON value or a small literal.
    public mutating func set(_ key: StaticString, to value: JSONValue) throws(ObjectError) {
        let valueStart = valueLength
        try append(value: value)
        try addOperation(key: key, valueStart: valueStart, valueLength: valueLength - valueStart, kind: 0)
    }

    /// Copies a complete raw JSON value synchronously into this edit plan.
    public mutating func setRaw(_ key: StaticString, value: ByteSlice) throws(ObjectError) {
        guard WireReader.isValidJSONValue(value) else { throw ObjectError(.invalidEditValue) }
        let valueStart = valueLength
        var fits = true
        value.withBytes { pointer, count in
            guard valueLength + count <= byteCapacity else { fits = false; return }
            for index in 0..<count { values[valueLength + index] = pointer.load(fromByteOffset: index, as: UInt8.self) }
            valueLength += count
        }
        guard fits else { throw ObjectError(.capacityExceeded) }
        try addOperation(key: key, valueStart: valueStart, valueLength: valueLength - valueStart, kind: 0)
    }

    /// Sets a field to JSON null.
    public mutating func setNull(_ key: StaticString) throws(ObjectError) {
        let valueStart = valueLength
        try appendByte(110); try appendByte(117); try appendByte(108); try appendByte(108)
        try addOperation(key: key, valueStart: valueStart, valueLength: 4, kind: 0)
    }

    /// Sets a field from already encoded JSON-string content.
    public mutating func setEncodedString(_ key: StaticString, value: ByteSlice) throws(ObjectError) {
        let valueStart = valueLength
        try appendByte(34)
        var valid = true
        var failure: ObjectError?
        value.withBytes { pointer, count in
            for index in 0..<count {
                let byte = pointer.load(fromByteOffset: index, as: UInt8.self)
                if byte < 0x20 { valid = false; return }
                do throws(ObjectError) { try appendByte(byte) }
                catch { failure = error; return }
            }
        }
        if let failure { throw failure }
        guard valid else { throw ObjectError(.invalidEditValue) }
        try appendByte(34)
        try addOperation(key: key, valueStart: valueStart, valueLength: valueLength - valueStart, kind: 0)
    }

    /// Sets a canonical hyphenated UUID string field without Foundation.
    public mutating func setUUID(_ key: StaticString, value: UUID16) throws(ObjectError) {
        let start = valueLength
        try appendByte(34)
        var raw = value.bytes
        var failure: ObjectError?
        withUnsafeBytes(of: &raw) { buffer in
            for index in 0..<16 {
                if index == 4 || index == 6 || index == 8 || index == 10 {
                    do throws(ObjectError) { try appendByte(45) }
                    catch { failure = error; return }
                }
                let byte = buffer[index]
                do throws(ObjectError) {
                    try appendByte(hexDigit(byte >> 4)); try appendByte(hexDigit(byte & 15))
                } catch { failure = error; return }
            }
        }
        if let failure { throw failure }
        try appendByte(34)
        try addOperation(key: key, valueStart: start, valueLength: valueLength - start, kind: 0)
    }

    /// Sets a signed integer without constructing a String.
    public mutating func setInteger(_ value: Int, forKey key: StaticString) throws(ObjectError) {
        let start = valueLength
        var magnitude = value < 0 ? UInt64(-(value + 1)) + 1 : UInt64(value)
        if value < 0 { try appendByte(45) }
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var count = 0
        repeat {
            digits[count] = UInt8(magnitude % 10) + 48
            magnitude /= 10
            count += 1
        } while magnitude > 0
        for index in stride(from: count - 1, through: 0, by: -1) { try appendByte(digits[index]) }
        try addOperation(key: key, valueStart: start, valueLength: valueLength - start, kind: 0)
    }

    /// Sets an unsigned integer without constructing an unbounded buffer.
    public mutating func setUnsignedInteger(_ value: UInt64, forKey key: StaticString) throws(ObjectError) {
        let start = valueLength
        var magnitude = value
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var count = 0
        repeat {
            digits[count] = UInt8(magnitude % 10) + 48
            magnitude /= 10
            count += 1
        } while magnitude > 0
        for index in stride(from: count - 1, through: 0, by: -1) { try appendByte(digits[index]) }
        try addOperation(key: key, valueStart: start, valueLength: valueLength - start, kind: 0)
    }

    /// Sets a Boolean without constructing a String.
    public mutating func setBoolean(_ value: Bool, forKey key: StaticString) throws(ObjectError) {
        let start = valueLength
        try appendStatic(value ? "true" : "false")
        try addOperation(key: key, valueStart: start, valueLength: valueLength - start, kind: 0)
    }

    /// Removes a field if present. Removing an absent field is idempotent.
    public mutating func remove(_ key: StaticString) throws(ObjectError) {
        try addOperation(key: key, valueStart: 0, valueLength: 0, kind: 1)
    }

    fileprivate mutating func commit<let fieldCapacity: Int>(into object: inout BoundedDynamicObject<byteCapacity, fieldCapacity>) throws(ObjectError) {
        try buildOutput()
        try object.replaceFromEditor(self)
    }

    private mutating func addOperation(key: StaticString, valueStart: Int, valueLength: Int, kind: UInt8) throws(ObjectError) {
        guard operationCount < 24, key.utf8CodeUnitCount <= 128 else { throw ObjectError(.capacityExceeded) }
        for index in 0..<key.utf8CodeUnitCount {
            let byte = key.utf8Start[index]
            guard byte >= 0x20, byte != 0x22, byte != 0x5C else { throw ObjectError(.invalidEditValue) }
        }
        var operation = EditOperation(); operation.keyLength = key.utf8CodeUnitCount; operation.valueStart = valueStart; operation.valueLength = valueLength; operation.kind = kind
        for index in 0..<operation.keyLength { operation.key[index] = key.utf8Start[index] }
        operations[operationCount] = operation; operationCount += 1
    }

    private mutating func append(value: JSONValue) throws(ObjectError) {
        switch value {
        case .null:
            try appendStatic("null")
        case let .string(value):
            try appendByte(34)
            for index in 0..<value.utf8CodeUnitCount {
                let byte = value.utf8Start[index]
                guard byte >= 0x20 else { throw ObjectError(.invalidEditValue) }
                if byte == 34 || byte == 92 { try appendByte(92) }
                try appendByte(byte)
            }
            try appendByte(34)
        case let .number(value):
            let bytes = ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
            guard WireReader.isValidJSONValue(bytes), let first = bytes.byte(at: 0), first == 45 || first == 48 || first >= 49 && first <= 57 else { throw ObjectError(.invalidEditValue) }
            try appendStatic(value)
        case let .bool(value):
            try appendStatic(value ? "true" : "false")
        }
    }

    private mutating func appendStatic(_ value: StaticString) throws(ObjectError) {
        guard valueLength + value.utf8CodeUnitCount <= byteCapacity else { throw ObjectError(.capacityExceeded) }
        for index in 0..<value.utf8CodeUnitCount { values[valueLength + index] = value.utf8Start[index] }
        valueLength += value.utf8CodeUnitCount
    }

    private mutating func appendByte(_ value: UInt8) throws(ObjectError) {
        guard valueLength < byteCapacity else { throw ObjectError(.capacityExceeded) }
        values[valueLength] = value; valueLength += 1
    }

    private func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? value + 48 : value + 87
    }

    private mutating func buildOutput() throws(ObjectError) {
        output = InlineArray(repeating: 0); outputLength = 0
        // WireReader indexes at most 24 top-level fields.
        var descriptors = InlineArray<24, DynamicFieldDescriptor>(repeating: DynamicFieldDescriptor()); var count = 0
        var failure: ObjectError?
        withUnsafeBytes(of: source) { (buffer: UnsafeRawBufferPointer) -> Void in
            let reader = WireReader(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), length: sourceLength)
            do throws(WireDecodeError) { try reader.validate() } catch { failure = objectError(error); return }
            do throws(ObjectError) { try fillDescriptors(reader, descriptors: &descriptors, count: &count) }
            catch { failure = error }
        }
        if let failure { throw failure }
        try outputByte(123); var wrote = false
        for index in 0..<count {
            let descriptor = descriptors[index]
            var operationIndex: Int? = nil
            for opIndex in 0..<operationCount {
                let operation = operations[opIndex]
                if operation.keyLength == descriptor.keyLength {
                    if sourceKeyEquals(descriptor, operation) { operationIndex = opIndex }
                }
            }
            if let operationIndex, operations[operationIndex].kind == 1 { continue }
            if wrote { try outputByte(44) }; wrote = true; try outputByte(34)
            for byteIndex in 0..<descriptor.keyLength { try outputByte(source[descriptor.keyStart + byteIndex]) }
            try outputByte(34); try outputByte(58)
            if let operationIndex {
                let op = operations[operationIndex]
                for byteIndex in 0..<op.valueLength { try outputByte(values[op.valueStart + byteIndex]) }
            } else {
                for byteIndex in 0..<descriptor.valueLength { try outputByte(source[descriptor.valueStart + byteIndex]) }
            }
        }
        for opIndex in 0..<operationCount where operations[opIndex].kind == 0 {
            let operation = operations[opIndex]
            var present = false
            for index in 0..<count where descriptors[index].keyLength == operation.keyLength {
                if sourceKeyEquals(descriptors[index], operation) { present = true }
            }
            if present { continue }
            if wrote { try outputByte(44) }; wrote = true; try outputByte(34)
            for byteIndex in 0..<operation.keyLength { try outputByte(operation.key[byteIndex]) }
            try outputByte(34); try outputByte(58)
            for byteIndex in 0..<operation.valueLength { try outputByte(values[operation.valueStart + byteIndex]) }
        }
        try outputByte(125)
    }

    private mutating func outputByte(_ value: UInt8) throws(ObjectError) {
        guard outputLength < byteCapacity else { throw ObjectError(.capacityExceeded) }
        output[outputLength] = value; outputLength += 1
    }

    private func sourceKeyEquals(_ descriptor: DynamicFieldDescriptor, _ operation: EditOperation) -> Bool {
        withUnsafeBytes(of: source) { sourceBytes in
            withUnsafeBytes(of: operation.key) { keyBytes in
                let sourceKey = ByteSlice(
                    bytes: sourceBytes.baseAddress!.advanced(by: descriptor.keyStart).assumingMemoryBound(to: UInt8.self),
                    length: descriptor.keyLength
                )
                let operationKey = ByteSlice(
                    bytes: keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    length: operation.keyLength
                )
                return sourceKey.semanticEquals(operationKey)
            }
        }
    }
}

private func fillDescriptors<let capacity: Int>(
    _ reader: WireReader,
    descriptors: inout InlineArray<capacity, DynamicFieldDescriptor>,
    count: inout Int
) throws(ObjectError) {
    var failure: ObjectError?
    do throws(WireDecodeError) {
        try reader.withObjectFields { field in
            guard failure == nil else { return }
            guard count < capacity else { failure = ObjectError(.capacityExceeded, byteOffset: count); return }
            descriptors[count] = DynamicFieldDescriptor(
                keyStart: field.keyRange.lowerBound,
                keyLength: field.keyRange.count,
                valueStart: field.valueRange.lowerBound,
                valueLength: field.valueRange.count
            )
            count += 1
        }
    } catch {
        failure = objectError(error)
    }
    if let failure { throw failure }
}

private func objectError(_ error: WireDecodeError) -> ObjectError {
    if case .fieldIndexOverflow = error.reason { return ObjectError(.fieldIndexOverflow, byteOffset: error.byteOffset) }
    return ObjectError(.invalidObject, byteOffset: error.byteOffset)
}
