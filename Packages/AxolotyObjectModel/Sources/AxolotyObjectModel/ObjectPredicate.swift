// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// A compact, fixed-inline predicate program.
public struct ObjectPredicate<let nodeCapacity: Int, let pathCapacity: Int, let literalCapacity: Int, let arenaCapacity: Int>: ~Copyable {
    private var nodes: InlineArray<nodeCapacity, PredicateNode>
    private var paths: InlineArray<pathCapacity, PredicatePath>
    private var segments: InlineArray<pathCapacity, PredicateSegment>
    private var literals: InlineArray<literalCapacity, PredicateLiteralRecord>
    private var arena: InlineArray<arenaCapacity, UInt8>
    private var nodeCount: Int
    private var pathCount: Int
    private var literalCount: Int
    private var arenaLength: Int

    /// Creates an empty predicate, which matches every object.
    public init() {
        nodes = InlineArray(repeating: PredicateNode.andRoot)
        paths = InlineArray(repeating: PredicatePath())
        segments = InlineArray(repeating: PredicateSegment())
        literals = InlineArray(repeating: PredicateLiteralRecord())
        arena = InlineArray(repeating: 0)
        nodeCount = 1; pathCount = 0; literalCount = 0; arenaLength = 0
    }

    /// Creates a single-condition predicate.
    public init(path: StaticString, expression: ObjectPredicateExpression) throws(ObjectError) {
        self.init()
        try appendCondition(path: path, expression: expression)
    }

    /// Decodes a Coaty `objectFilter` object using ``AxolotyWire`` tokenization.
    public init(decoding bytes: ByteSlice) throws(ObjectError) {
        var candidate = Self()
        guard bytes.wireValueKind == .object else { throw ObjectError(.invalidPredicate) }
        var failure: ObjectError?
        bytes.withBytes { pointer, count in
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            do throws(WireDecodeError) { try reader.validate() } catch { failure = ObjectError(.invalidPredicate); return }
            guard let conditions = reader.readField("conditions") else { return }
            candidate.appendConditionValue(conditions, parent: 0, failure: &failure)
        }
        if let failure { throw failure }
        self = candidate
    }

    /// Appends a condition to the implicit top-level AND group.
    public mutating func appendCondition(path: StaticString, expression: ObjectPredicateExpression) throws(ObjectError) {
        var candidate = Self()
        candidate.copyState(from: self)
        let pathIndex = try candidate.appendPath(path)
        let expressionInfo = try candidate.appendExpression(expression)
        _ = try candidate.appendNode(PredicateNode.condition(path: pathIndex, operation: expressionInfo.operation, operand: expressionInfo.operand, operandCount: expressionInfo.count), parent: 0)
        self = candidate
    }

    /// Tests one bounded dynamic object without copying its fields.
    public borrowing func matches<let byteCapacity: Int, let fieldCapacity: Int>(object: borrowing BoundedDynamicObject<byteCapacity, fieldCapacity>) -> Bool {
        object.withFields { fields in matches(fields: fields) }
    }

    /// Tests a borrowed field view. The result is the only value that escapes.
    public borrowing func matches(fields: borrowing ObjectFields) -> Bool {
        evaluateNode(0, fields: fields)
    }

    /// Encodes the canonical Coaty `objectFilter` value into a caller-owned
    /// wire writer.
    ///
    /// A match-all predicate encodes as `{}`. One root condition uses the
    /// direct `[property, expression]` form; multiple conditions and logical
    /// groups use the Coaty `and`/`or` condition-set form. The writer position
    /// is rewound if the bounded output buffer is too small.
    public borrowing func encode(to writer: inout WireWriter) throws(WireEncodeError) {
        let checkpoint = writer.position
        do throws(WireEncodeError) {
            try writer.beginObject()
            guard nodeCount > 1 else {
                try writer.endObject()
                return
            }
            try writer.writeKey("conditions")
            let first = nodes[0].firstChild
            guard first >= 0 else {
                try writer.endObject()
                return
            }
            if nodes[first].kind == 0, nodes[first].nextSibling < 0 {
                try encodeCondition(nodes[first], to: &writer)
            } else if nodes[first].kind == 1, nodes[first].nextSibling < 0 {
                try encodeGroup(first, to: &writer)
            } else if nodes[first].kind == 2, nodes[first].nextSibling < 0 {
                try encodeGroup(first, to: &writer)
            } else {
                try encodeGroupChildren(first, kind: 1, to: &writer)
            }
            try writer.endObject()
        } catch {
            writer.rewind(to: checkpoint)
            throw error
        }
    }

    private borrowing func encodeGroupChildren(_ first: Int, kind: UInt8, to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginObject()
        try writer.writeKey(kind == 2 ? "or" : "and")
        try writer.beginArray()
        var child = first
        var isFirst = true
        while child >= 0 {
            if !isFirst { try writer.writeComma() }
            try encodeNode(child, to: &writer)
            isFirst = false
            child = nodes[child].nextSibling
        }
        try writer.endArray()
        try writer.endObject()
    }

    private borrowing func encodeGroup(_ index: Int, to writer: inout WireWriter) throws(WireEncodeError) {
        try encodeGroupChildren(nodes[index].firstChild, kind: nodes[index].kind, to: &writer)
    }

    private borrowing func encodeNode(_ index: Int, to writer: inout WireWriter) throws(WireEncodeError) {
        if nodes[index].kind == 0 { try encodeCondition(nodes[index], to: &writer) }
        else { try encodeGroup(index, to: &writer) }
    }

    private borrowing func encodeCondition(_ node: PredicateNode, to writer: inout WireWriter) throws(WireEncodeError) {
        try writer.beginArray()
        try encodePath(node.path, to: &writer)
        try writer.writeComma()
        try writer.beginArray()
        try writer.writeInt(Int(node.operation.rawValue))
        for offset in 0..<node.operandCount {
            try writer.writeComma()
            try writeLiteral(node.operand + offset, to: &writer)
        }
        try writer.endArray()
        try writer.endArray()
    }

    private borrowing func encodePath(_ index: Int, to writer: inout WireWriter) throws(WireEncodeError) {
        let path = paths[index]
        if path.segmentCount == 1, !segmentContainsDot(path.firstSegment) {
            try writeSegment(path.firstSegment, to: &writer)
            return
        }
        try writer.beginArray()
        for offset in 0..<path.segmentCount {
            if offset > 0 { try writer.writeComma() }
            try writeSegment(path.firstSegment + offset, to: &writer)
        }
        try writer.endArray()
    }

    private borrowing func segmentContainsDot(_ index: Int) -> Bool {
        withUnsafeBytes(of: arena) { buffer in
            let segment = segments[index]
            let pointer = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: segment.start)
            for offset in 0..<segment.length where pointer[offset] == 0x2E { return true }
            return false
        }
    }

    private borrowing func writeSegment(_ index: Int, to writer: inout WireWriter) throws(WireEncodeError) {
        var failure: WireEncodeError?
        withUnsafeBytes(of: arena) { buffer in
            do throws(WireEncodeError) {
                let segment = segments[index]
                let slice = ByteSlice(
                    bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: segment.start),
                    length: segment.length
                )
                try writer.writeEncodedStringValue(slice)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    private borrowing func writeLiteral(_ index: Int, to writer: inout WireWriter) throws(WireEncodeError) {
        var failure: WireEncodeError?
        withUnsafeBytes(of: arena) { buffer in
            do throws(WireEncodeError) {
                let literal = literals[index]
                let slice = ByteSlice(
                    bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: literal.start),
                    length: literal.length
                )
                try writer.writeRawValue(slice)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    private mutating func appendConditionValue(_ bytes: ByteSlice, parent: Int, failure: inout ObjectError?) {
        bytes.withBorrowedWireValue { value in
            appendConditionValue(value, parent: parent, failure: &failure)
        }
    }

    private mutating func appendConditionValue(_ bytes: borrowing WireValueView, parent: Int, failure: inout ObjectError?) {
        guard failure == nil else { return }
        if bytes.kind == .array {
            var pathIndex: Int?
            var expressionInfo: (operation: ObjectPredicateOperator, operand: Int, count: Int)?
            var index = 0
            var wireFailure: WireDecodeError?
            withUnsafeMutablePointer(to: &self) { state in
                do throws(WireDecodeError) {
                    try bytes.withBorrowedArrayElements { element in
                        if index == 0 { pathIndex = state.pointee.appendPathValue(element, failure: &failure) }
                        else if index == 1 { expressionInfo = state.pointee.appendExpressionValue(element, failure: &failure) }
                        else if failure == nil { failure = ObjectError(.invalidPredicateExpression) }
                        index += 1
                    }
                } catch { wireFailure = error }
            }
            if wireFailure != nil, failure == nil { failure = ObjectError(.invalidPredicateExpression) }
            guard failure == nil else { return }
            guard index == 2, let pathIndex, let expressionInfo else { failure = ObjectError(.invalidPredicateExpression); return }
            do throws(ObjectError) { _ = try appendNode(PredicateNode.condition(path: pathIndex, operation: expressionInfo.operation, operand: expressionInfo.operand, operandCount: expressionInfo.count), parent: parent) }
            catch { failure = error }
            return
        }
        guard bytes.kind == .object else { failure = ObjectError(.invalidPredicateExpression); return }
        var groupCount = 0
        do throws(WireDecodeError) {
            try bytes.withObjectFields { field in
                field.withBorrowedKey { key in
                    let isAnd = key.semanticEquals("and")
                    let isOr = key.semanticEquals("or")
                    guard isAnd || isOr else { failure = ObjectError(.invalidPredicateExpression); return }
                    groupCount += 1
                    guard groupCount == 1 else { failure = ObjectError(.invalidPredicateExpression); return }
                    field.withBorrowedValue { group in
                        guard group.kind == .array else { failure = ObjectError(.invalidPredicateExpression); return }
                        let groupNode: Int
                        do throws(ObjectError) { groupNode = try appendNode(PredicateNode.group(kind: isAnd ? 1 : 2), parent: parent) }
                        catch { failure = error; return }
                        var wireFailure: WireDecodeError?
                        withUnsafeMutablePointer(to: &self) { state in
                            do throws(WireDecodeError) {
                                try group.withBorrowedArrayElements { condition in
                                    state.pointee.appendConditionValue(condition, parent: groupNode, failure: &failure)
                                }
                            } catch { wireFailure = error }
                        }
                        if wireFailure != nil, failure == nil { failure = ObjectError(.invalidPredicateExpression) }
                    }
                }
            }
        } catch { if failure == nil { failure = ObjectError(.invalidPredicateExpression) } }
        if failure == nil, groupCount != 1 { failure = ObjectError(.invalidPredicateExpression) }
    }

    private mutating func copyState(from source: borrowing Self) {
        for index in 0..<source.nodeCount { nodes[index] = source.nodes[index] }
        for index in 0..<source.pathCount { paths[index] = source.paths[index] }
        for index in 0..<pathCapacity where source.segments[index].length > 0 { segments[index] = source.segments[index] }
        for index in 0..<source.literalCount { literals[index] = source.literals[index] }
        for index in 0..<source.arenaLength { arena[index] = source.arena[index] }
        nodeCount = source.nodeCount; pathCount = source.pathCount; literalCount = source.literalCount; arenaLength = source.arenaLength
    }

    private mutating func appendExpression(_ expression: ObjectPredicateExpression) throws(ObjectError) -> (operation: ObjectPredicateOperator, operand: Int, count: Int) {
        switch expression {
        case .exists: return (.exists, 0, 0)
        case .notExists: return (.notExists, 0, 0)
        case .lessThan(let value): return try appendOne(.lessThan, value)
        case .lessThanOrEqual(let value): return try appendOne(.lessThanOrEqual, value)
        case .greaterThan(let value): return try appendOne(.greaterThan, value)
        case .greaterThanOrEqual(let value): return try appendOne(.greaterThanOrEqual, value)
        case .like(let value): return try appendOne(.like, value)
        case .equals(let value): return try appendOne(.equals, value)
        case .notEquals(let value): return try appendOne(.notEquals, value)
        case .contains(let value): return try appendOne(.contains, value)
        case .notContains(let value): return try appendOne(.notContains, value)
        case .valuesIn(let value): return try appendOne(.valuesIn, value, requireArray: true)
        case .valuesNotIn(let value): return try appendOne(.valuesNotIn, value, requireArray: true)
        case .between(let first, let second):
            let start = try appendLiteral(first); _ = try appendLiteral(second)
            return (.between, start, 2)
        case .notBetween(let first, let second):
            let start = try appendLiteral(first); _ = try appendLiteral(second)
            return (.notBetween, start, 2)
        }
    }

    private mutating func appendOne(_ operation: ObjectPredicateOperator, _ value: ObjectPredicateLiteral, requireArray: Bool = false) throws(ObjectError) -> (ObjectPredicateOperator, Int, Int) {
        let index = try appendLiteral(value)
        if requireArray, !literalIsArray(index) { throw ObjectError(.invalidPredicateExpression) }
        return (operation, index, 1)
    }

    private mutating func appendExpressionValue(_ bytes: borrowing WireValueView, failure: inout ObjectError?) -> (operation: ObjectPredicateOperator, operand: Int, count: Int)? {
        guard bytes.kind == .array else { if failure == nil { failure = ObjectError(.invalidPredicateExpression) }; return nil }
        var operation: ObjectPredicateOperator?
        var operandIndexes = InlineArray<2, Int>(repeating: -1)
        var operandCount = 0
        var wireFailure: WireDecodeError?
        withUnsafeMutablePointer(to: &self) { state in
            do throws(WireDecodeError) {
                try bytes.withBorrowedArrayElements { element in
                    if operandCount == 0 { operation = Self.parseOperator(element) }
                    else if operandCount <= 2 { operandIndexes[operandCount - 1] = state.pointee.appendLiteralValue(element, failure: &failure) ?? -1 }
                    else { failure = ObjectError(.invalidPredicateExpression) }
                    operandCount += 1
                }
            } catch { wireFailure = error }
        }
        if wireFailure != nil, failure == nil { failure = ObjectError(.invalidPredicateExpression) }
        guard failure == nil else { return nil }
        guard let operation else { failure = ObjectError(.invalidPredicateExpression); return nil }
        let expected: Int
        switch operation { case .exists, .notExists: expected = 1; case .between, .notBetween: expected = 3; default: expected = 2 }
        guard operandCount == expected else { if failure == nil { failure = ObjectError(.invalidPredicateExpression) }; return nil }
        if operation == .exists || operation == .notExists { return (operation, 0, 0) }
        let firstIndex = operandIndexes[0]
        guard firstIndex >= 0 else { if failure == nil { failure = ObjectError(.invalidPredicateExpression) }; return nil }
        if operation == .between || operation == .notBetween {
            guard operandIndexes[1] == firstIndex + 1 else { if failure == nil { failure = ObjectError(.invalidPredicateExpression) }; return nil }
        }
        if operation == .valuesIn || operation == .valuesNotIn, !literalIsArray(firstIndex) { if failure == nil { failure = ObjectError(.invalidPredicateExpression) }; return nil }
        return (operation, firstIndex, operation == .between || operation == .notBetween ? 2 : 1)
    }

    private static func parseOperator(_ bytes: borrowing WireValueView) -> ObjectPredicateOperator? {
        guard bytes.length > 0 else { return nil }
        var value = 0
        for index in 0..<bytes.length {
            guard let byte = bytes.byte(at: index), byte >= 48 && byte <= 57 else { return nil }
            let (next, overflow) = value.multipliedReportingOverflow(by: 10)
            let (result, digitOverflow) = next.addingReportingOverflow(Int(byte - 48))
            guard !overflow && !digitOverflow else { return nil }
            value = result
        }
        guard value <= Int(UInt8.max) else { return nil }
        return ObjectPredicateOperator(rawValue: UInt8(value))
    }

    private mutating func appendPath(_ path: StaticString) throws(ObjectError) -> Int {
        guard pathCount < pathCapacity else { throw ObjectError(.capacityExceeded) }
        let pathIndex = pathCount; pathCount += 1
        let first = segmentsCount; var segmentCount = 0
        var start = 0
        for index in 0...path.utf8CodeUnitCount {
            if index == path.utf8CodeUnitCount || path.utf8Start[index] == 46 {
                guard index > start else { throw ObjectError(.invalidPredicatePath) }
                try appendSegment(path.utf8Start.advanced(by: start), length: index - start)
                segmentCount += 1; start = index + 1
            }
        }
        paths[pathIndex] = PredicatePath(firstSegment: first, segmentCount: segmentCount)
        return pathIndex
    }

    private mutating func appendPathValue(_ value: borrowing WireValueView, failure: inout ObjectError?) -> Int? {
        guard pathCount < pathCapacity else { failure = ObjectError(.capacityExceeded); return nil }
        let pathIndex = pathCount; pathCount += 1
        let first = segmentsCount; var segmentCount = 0
        if value.kind == .string {
            value.withBorrowedSubView(from: 1, length: max(0, value.length - 2)) { content in
                var start = 0
                for index in 0...content.length {
                    if index == content.length || content.byte(at: index) == 46 {
                        guard index > start else { failure = ObjectError(.invalidPredicatePath); return }
                        appendDecodedSegment(content, start: start, length: index - start, failure: &failure)
                        segmentCount += 1; start = index + 1
                    }
                }
            }
        } else if value.kind == .array {
            do throws(WireDecodeError) { try value.withBorrowedArrayElements { segment in
                guard segment.kind == .string, segment.length >= 2 else { failure = ObjectError(.invalidPredicatePath); return }
                appendDecodedSegment(segment, start: 1, length: segment.length - 2, failure: &failure); segmentCount += 1
            }} catch { failure = ObjectError(.invalidPredicatePath) }
        } else { failure = ObjectError(.invalidPredicatePath) }
        guard failure == nil, segmentCount > 0 else { return nil }
        paths[pathIndex] = PredicatePath(firstSegment: first, segmentCount: segmentCount)
        return pathIndex
    }

    private var segmentsCount: Int {
        var count = 0
        for index in 0..<pathCapacity where segments[index].length > 0 { count = index + 1 }
        return count
    }

    private mutating func appendSegment(_ pointer: UnsafePointer<UInt8>, length: Int) throws(ObjectError) {
        guard arenaLength + length <= arenaCapacity else { throw ObjectError(.capacityExceeded) }
        guard segmentsCount < pathCapacity else { throw ObjectError(.capacityExceeded) }
        let segmentIndex = segmentsCount
        for index in 0..<length { arena[arenaLength + index] = pointer[index] }
        segments[segmentIndex] = PredicateSegment(start: arenaLength, length: length)
        arenaLength += length
    }

    private mutating func appendSegment(_ value: borrowing WireValueView, start: Int, length: Int, failure: inout ObjectError?) {
        guard failure == nil, arenaLength + length <= arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
        guard segmentsCount < pathCapacity else { failure = ObjectError(.capacityExceeded); return }
        let segmentIndex = segmentsCount
        for index in 0..<length { arena[arenaLength + index] = value.byte(at: start + index)! }
        segments[segmentIndex] = PredicateSegment(start: arenaLength, length: length)
        arenaLength += length
    }

    private mutating func appendDecodedSegment(_ value: borrowing WireValueView, start: Int, length: Int, failure: inout ObjectError?) {
        guard failure == nil, segmentsCount < pathCapacity else {
            failure = failure ?? ObjectError(.capacityExceeded); return
        }
        let segmentIndex = segmentsCount
        let arenaStart = arenaLength
        do throws(WireDecodeError) {
            try value.withDecodedScalars(in: start..<(start + length)) { scalar in
                appendUTF8Scalar(scalar, failure: &failure)
            }
        } catch { failure = ObjectError(.invalidPredicatePath) }
        guard failure == nil else { arenaLength = arenaStart; return }
        segments[segmentIndex] = PredicateSegment(start: arenaStart, length: arenaLength - arenaStart)
    }

    private mutating func appendUTF8Scalar(_ scalar: UInt32, failure: inout ObjectError?) {
        guard failure == nil else { return }
        if scalar <= 0x7F {
            guard arenaLength < arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
            arena[arenaLength] = UInt8(scalar); arenaLength += 1
        } else if scalar <= 0x7FF {
            guard arenaLength + 2 <= arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
            arena[arenaLength] = UInt8(0xC0 | (scalar >> 6)); arena[arenaLength + 1] = UInt8(0x80 | (scalar & 0x3F)); arenaLength += 2
        } else if scalar <= 0xFFFF {
            guard arenaLength + 3 <= arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
            arena[arenaLength] = UInt8(0xE0 | (scalar >> 12)); arena[arenaLength + 1] = UInt8(0x80 | ((scalar >> 6) & 0x3F)); arena[arenaLength + 2] = UInt8(0x80 | (scalar & 0x3F)); arenaLength += 3
        } else {
            guard arenaLength + 4 <= arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
            arena[arenaLength] = UInt8(0xF0 | (scalar >> 18)); arena[arenaLength + 1] = UInt8(0x80 | ((scalar >> 12) & 0x3F)); arena[arenaLength + 2] = UInt8(0x80 | ((scalar >> 6) & 0x3F)); arena[arenaLength + 3] = UInt8(0x80 | (scalar & 0x3F)); arenaLength += 4
        }
    }

    private mutating func appendLiteral(_ literal: ObjectPredicateLiteral) throws(ObjectError) -> Int {
        guard literalCount < literalCapacity else { throw ObjectError(.capacityExceeded) }
        let start = arenaLength
        switch literal {
        case .raw(let value):
            guard WireReader.isValidJSONValue(value) else { throw ObjectError(.invalidPredicateExpression) }
            try copy(value)
        case .null: try appendStatic("null")
        case .bool(let value): try appendStatic(value ? "true" : "false")
        case .string(let value):
            try appendByte(34)
            for index in 0..<value.utf8CodeUnitCount { let byte = value.utf8Start[index]; guard byte >= 0x20 else { throw ObjectError(.invalidPredicateExpression) }; if byte == 34 || byte == 92 { try appendByte(92) }; try appendByte(byte) }
            try appendByte(34)
        case .number(let value):
            let bytes = ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount)
            guard WireReader.isValidJSONValue(bytes), bytes.wireValueKind == .number else { throw ObjectError(.invalidPredicateExpression) }
            try copy(bytes)
        }
        literals[literalCount] = PredicateLiteralRecord(start: start, length: arenaLength - start)
        literalCount += 1
        return literalCount - 1
    }

    private mutating func appendLiteralValue(_ value: borrowing WireValueView, failure: inout ObjectError?) -> Int? {
        guard value.length <= WireBufferConfig.maxPayloadSize,
              value.kind != .invalid else {
            failure = ObjectError(.invalidPredicateExpression)
            return nil
        }
        guard literalCount < literalCapacity,
              arenaLength + value.length <= arenaCapacity else {
            failure = ObjectError(.capacityExceeded)
            return nil
        }
        let start = arenaLength
        for index in 0..<value.length { arena[arenaLength + index] = value.byte(at: index)! }
        arenaLength += value.length
        literals[literalCount] = PredicateLiteralRecord(start: start, length: value.length)
        literalCount += 1
        return literalCount - 1
    }

    private mutating func copy(_ value: ByteSlice) throws(ObjectError) {
        guard arenaLength + value.length <= arenaCapacity else { throw ObjectError(.capacityExceeded) }
        for index in 0..<value.length { arena[arenaLength + index] = value.byte(at: index)! }
        arenaLength += value.length
    }

    private mutating func copyBorrowed(_ value: borrowing WireValueView) throws(ObjectError) {
        guard arenaLength + value.length <= arenaCapacity else { throw ObjectError(.capacityExceeded) }
        for index in 0..<value.length { arena[arenaLength + index] = value.byte(at: index)! }
        arenaLength += value.length
    }

    private mutating func appendStatic(_ value: StaticString) throws(ObjectError) {
        guard arenaLength + value.utf8CodeUnitCount <= arenaCapacity else { throw ObjectError(.capacityExceeded) }
        for index in 0..<value.utf8CodeUnitCount { arena[arenaLength + index] = value.utf8Start[index] }
        arenaLength += value.utf8CodeUnitCount
    }

    private mutating func appendByte(_ byte: UInt8) throws(ObjectError) {
        guard arenaLength < arenaCapacity else { throw ObjectError(.capacityExceeded) }
        arena[arenaLength] = byte; arenaLength += 1
    }

    private borrowing func literalIsArray(_ index: Int) -> Bool { literalSlice(index) { $0.wireValueKind == .array } }

    private mutating func appendNode(_ node: PredicateNode, parent: Int? = nil) throws(ObjectError) -> Int {
        guard nodeCount < nodeCapacity else { throw ObjectError(.capacityExceeded) }
        let index = nodeCount
        nodes[index] = node
        nodeCount += 1
        if let parent {
            if nodes[parent].firstChild < 0 { nodes[parent].firstChild = index }
            else {
                var sibling = nodes[parent].firstChild
                while nodes[sibling].nextSibling >= 0 { sibling = nodes[sibling].nextSibling }
                nodes[sibling].nextSibling = index
            }
        }
        return index
    }

    private borrowing func evaluateNode(_ index: Int, fields: borrowing ObjectFields) -> Bool {
        let node = nodes[index]
        if node.kind == 0 { return evaluateCondition(node, fields: fields) }
        var child = node.firstChild
        var result = node.kind == 1
        while child >= 0 {
            let value = evaluateNode(child, fields: fields)
            if node.kind == 1 { result = result && value; if !result { return false } }
            else { result = result || value; if result { return true } }
            child = nodes[child].nextSibling
        }
        return result
    }

    private borrowing func evaluateCondition(_ node: PredicateNode, fields: borrowing ObjectFields) -> Bool {
        if node.operation == .notExists { return !resolvePath(node.path, fields: fields) { _, _ in true } }
        guard node.operation != .exists else { return resolvePath(node.path, fields: fields) { _, _ in true } }
        var result = false
        _ = resolvePath(node.path, fields: fields) { raw, _ in result = evaluate(raw, operation: node.operation, operand: node.operand, count: node.operandCount); return result }
        return result
    }

    private borrowing func resolvePath(_ pathIndex: Int, fields: borrowing ObjectFields, _ body: (ByteSlice, WireValueKind) -> Bool) -> Bool {
        let path = paths[pathIndex]
        return resolveSegment(path, segment: 0, fields: fields, body)
    }

    private borrowing func resolveSegment(_ path: PredicatePath, segment: Int, fields: borrowing ObjectFields, _ body: (ByteSlice, WireValueKind) -> Bool) -> Bool {
        return withSegment(path, segment) { key in
            var found = false
            _ = fields.withValue(for: key) { value in
                value.withRaw { raw in
                    found = segment + 1 == path.segmentCount
                        ? body(raw, raw.wireValueKind)
                        : resolveNested(raw, path: path, segment: segment + 1, body)
                }
            }
            return found
        }
    }

    private borrowing func resolveNested(_ raw: ByteSlice, path: PredicatePath, segment: Int, _ body: (ByteSlice, WireValueKind) -> Bool) -> Bool {
        guard raw.wireValueKind == .object else { return false }
        var result = false
        do throws(WireDecodeError) {
            try raw.withBorrowedObjectFields { field in
                field.withBorrowedKey { key in
                    _ = withSegment(path, segment) { wanted in
                        guard key.semanticEquals(wanted) else { return false }
                        field.withBorrowedValue { child in
                            result = resolveNestedView(child, path: path, segment: segment, body)
                        }
                        return result
                    }
                }
            }
        } catch { return false }
        return result
    }

    private borrowing func resolveNestedView(
        _ raw: borrowing WireValueView,
        path: PredicatePath,
        segment: Int,
        _ body: (ByteSlice, WireValueKind) -> Bool
    ) -> Bool {
        if segment + 1 == path.segmentCount {
            var result = false
            raw.withBorrowedByteSlice { value in
                result = body(value, value.wireValueKind)
            }
            return result
        }
        guard raw.kind == .object else { return false }
        var result = false
        do throws(WireDecodeError) {
            try raw.withObjectFields { field in
                field.withBorrowedKey { key in
                    _ = withSegment(path, segment + 1) { wanted in
                        guard key.semanticEquals(wanted) else { return false }
                        field.withBorrowedValue { child in
                            result = resolveNestedView(child, path: path, segment: segment + 1, body)
                        }
                        return result
                    }
                }
            }
        } catch { return false }
        return result
    }

    /// Runs a segment callback while the segment slice is borrowed from the
    /// predicate arena.  The callback result is deliberately non-generic so a
    /// `ByteSlice` cannot be returned accidentally.
    private borrowing func withSegment(_ path: PredicatePath, _ index: Int, _ body: (ByteSlice) -> Bool) -> Bool {
        withUnsafeBytes(of: arena) { buffer in
            let segment = segments[path.firstSegment + index]
            return body(ByteSlice(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: segment.start), length: segment.length))
        }
    }

    /// Runs a literal callback while the literal slice is borrowed from the
    /// predicate arena.  Predicate evaluation only needs a scalar result;
    /// keeping that result non-generic prevents borrowed bytes escaping.
    private borrowing func literalSlice(_ index: Int, _ body: (ByteSlice) -> Bool) -> Bool {
        withUnsafeBytes(of: arena) { buffer in body(ByteSlice(bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: literals[index].start), length: literals[index].length)) }
    }

    private borrowing func evaluate(_ raw: ByteSlice, operation: ObjectPredicateOperator, operand: Int, count: Int) -> Bool {
        switch operation {
        case .equals: return literalSlice(operand) { ObjectPredicateMatcher.jsonEqual(raw, $0) }
        case .notEquals: return literalSlice(operand) { !ObjectPredicateMatcher.jsonEqual(raw, $0) }
        case .contains: return literalSlice(operand) { ObjectPredicateMatcher.jsonContains(raw, $0) }
        case .notContains: return literalSlice(operand) { !ObjectPredicateMatcher.jsonContains(raw, $0) }
        case .valuesIn: return literalSlice(operand) { ObjectPredicateMatcher.jsonIn(raw, $0) }
        case .valuesNotIn: return literalSlice(operand) { !ObjectPredicateMatcher.jsonIn(raw, $0) }
        case .like: return literalSlice(operand) { ObjectPredicateMatcher.wildcard(raw, $0) }
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return literalSlice(operand) { compare(raw, $0, operation) }
        case .between, .notBetween:
            var inside = false
            _ = literalSlice(operand) { first in
            _ = literalSlice(operand + 1) { second in
                guard let boundsComparison = PredicateDecimalComparison.compare(first, second) else { return false }
                if boundsComparison <= 0 {
                    inside = compare(raw, first, .greaterThanOrEqual) && compare(raw, second, .lessThanOrEqual)
                } else {
                    inside = compare(raw, second, .greaterThanOrEqual) && compare(raw, first, .lessThanOrEqual)
                }
                return inside
            }
            return inside
        }
            return operation == .between ? inside : !inside
        case .exists, .notExists: return count == 0
        }
    }

    private func compare(_ lhs: ByteSlice, _ rhs: ByteSlice, _ operation: ObjectPredicateOperator) -> Bool {
        let result: Int
        if lhs.wireValueKind == .number && rhs.wireValueKind == .number {
            guard let numberResult = PredicateDecimalComparison.compare(lhs, rhs) else { return false }
            result = numberResult
        }
        else if lhs.wireValueKind == .string && rhs.wireValueKind == .string {
            guard let stringResult = ObjectPredicateMatcher.compareStrings(lhs, rhs) else { return false }
            result = stringResult
        }
        else { return false }
        switch operation { case .lessThan: return result < 0; case .lessThanOrEqual: return result <= 0; case .greaterThan: return result > 0; case .greaterThanOrEqual: return result >= 0; default: return false }
    }

}

private struct PredicateNode {
    var kind: UInt8 = 0
    var operation: ObjectPredicateOperator = .exists
    var firstChild: Int = -1
    var nextSibling: Int = -1
    var path: Int = 0
    var operand: Int = 0
    var operandCount: Int = 0
    static let andRoot = PredicateNode(kind: 1)
    static func group(kind: UInt8) -> PredicateNode { PredicateNode(kind: kind) }
    static func condition(path: Int, operation: ObjectPredicateOperator, operand: Int, operandCount: Int) -> PredicateNode { PredicateNode(kind: 0, operation: operation, path: path, operand: operand, operandCount: operandCount) }
}

private struct PredicatePath { var firstSegment = 0; var segmentCount = 0 }
private struct PredicateSegment { var start = 0; var length = 0 }
private struct PredicateLiteralRecord { var start = 0; var length = 0 }
