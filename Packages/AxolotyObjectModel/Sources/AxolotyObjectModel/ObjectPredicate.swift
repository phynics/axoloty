// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

private enum PredicateScratchLimits {
    // Predicate string operations use the same measured maximum as one wire
    // value. Overflow is a deterministic non-match, never truncation.
    static let scalarCapacity = 512
}

/// The Coaty object-filter operators, retaining their protocol integer values.
public enum ObjectPredicateOperator: UInt8, Sendable, Equatable {
    /// Strictly less than.
    case lessThan = 0
    /// Less than or equal to.
    case lessThanOrEqual = 1
    /// Strictly greater than.
    case greaterThan = 2
    /// Greater than or equal to.
    case greaterThanOrEqual = 3
    /// Inclusive range test.
    case between = 4
    /// Negated inclusive range test.
    case notBetween = 5
    /// Coaty SQL-like wildcard matching.
    case like = 6
    /// Recursive JSON equality.
    case equals = 7
    /// Negated recursive JSON equality.
    case notEquals = 8
    /// Tests field presence, including explicit null.
    case exists = 9
    /// Tests field absence.
    case notExists = 10
    /// Recursive containment.
    case contains = 11
    /// Negated recursive containment.
    case notContains = 12
    /// Top-level membership in an operand array.
    case valuesIn = 13
    /// Negated top-level membership in an operand array.
    case valuesNotIn = 14
}

/// A bounded predicate operand. Raw values are copied into the predicate arena.
public enum ObjectPredicateLiteral {
    /// A complete borrowed JSON value.
    case raw(ByteSlice)
    /// JSON null.
    case null
    /// JSON boolean.
    case bool(Bool)
    /// A JSON string literal without Foundation.
    case string(StaticString)
    /// A JSON number lexeme, retained exactly.
    case number(StaticString)
}

/// One typed Coaty predicate expression.
public enum ObjectPredicateExpression {
    /// A one-operand comparison.
    case lessThan(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case lessThanOrEqual(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case greaterThan(ObjectPredicateLiteral)
    /// A one-operand comparison.
    case greaterThanOrEqual(ObjectPredicateLiteral)
    /// An inclusive range.
    case between(ObjectPredicateLiteral, ObjectPredicateLiteral)
    /// A negated inclusive range.
    case notBetween(ObjectPredicateLiteral, ObjectPredicateLiteral)
    /// A wildcard string pattern.
    case like(ObjectPredicateLiteral)
    /// Recursive equality.
    case equals(ObjectPredicateLiteral)
    /// Negated recursive equality.
    case notEquals(ObjectPredicateLiteral)
    /// Presence test.
    case exists
    /// Absence test.
    case notExists
    /// Recursive containment.
    case contains(ObjectPredicateLiteral)
    /// Negated recursive containment.
    case notContains(ObjectPredicateLiteral)
    /// Top-level membership; the literal must be a JSON array.
    case valuesIn(ObjectPredicateLiteral)
    /// Negated top-level membership; the literal must be a JSON array.
    case valuesNotIn(ObjectPredicateLiteral)
}

/// Short aliases used by schema code when the predicate context is already clear.
public typealias PredicateOperator = ObjectPredicateOperator
/// Short alias for a predicate literal.
public typealias PredicateLiteral = ObjectPredicateLiteral
/// Short alias for a predicate expression.
public typealias PredicateExpression = ObjectPredicateExpression

/// A compact, fixed-inline predicate program.
public struct ObjectPredicate<let nodeCapacity: Int, let pathCapacity: Int, let literalCapacity: Int, let arenaCapacity: Int>: ~Copyable {
    private var nodes: InlineArray<nodeCapacity, PredicateNode>
    private var paths: InlineArray<pathCapacity, PredicatePath>
    private var segments: InlineArray<pathCapacity, PredicateSegment>
    private var literals: InlineArray<literalCapacity, PredicateLiteral>
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
        literals = InlineArray(repeating: PredicateLiteral())
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
        guard WireValueReader(bytes).kind == .object else { throw ObjectError(.invalidPredicate) }
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

    private mutating func appendConditionValue(_ bytes: ByteSlice, parent: Int, failure: inout ObjectError?) {
        guard failure == nil else { return }
        let value = WireValueReader(bytes)
        if value.kind == .array {
            var pathIndex: Int?
            var expressionInfo: (operation: ObjectPredicateOperator, operand: Int, count: Int)?
            var index = 0
            do throws(WireDecodeError) {
                try value.withArrayElements { element in
                    if index == 0 { pathIndex = self.appendPathValue(element, failure: &failure) }
                    else if index == 1 { expressionInfo = self.appendExpressionValue(element, failure: &failure) }
                    else if failure == nil { failure = ObjectError(.invalidPredicateExpression) }
                    index += 1
                }
            } catch { failure = ObjectError(.invalidPredicateExpression) }
            guard failure == nil, index == 2, let pathIndex, let expressionInfo else { failure = ObjectError(.invalidPredicateExpression); return }
            do throws(ObjectError) { _ = try appendNode(PredicateNode.condition(path: pathIndex, operation: expressionInfo.operation, operand: expressionInfo.operand, operandCount: expressionInfo.count), parent: parent) }
            catch { failure = error }
            return
        }
        guard value.kind == .object else { failure = ObjectError(.invalidPredicateExpression); return }
        do throws(WireDecodeError) {
            try value.withObjectFields { field in
                field.withKey { key in
                    let isAnd = key.semanticEquals("and")
                    let isOr = key.semanticEquals("or")
                    guard isAnd || isOr else { return }
                    field.withValue { group in
                        let groupReader = WireValueReader(group)
                        guard groupReader.kind == .array else { failure = ObjectError(.invalidPredicateExpression); return }
                        let groupNode: Int
                        do throws(ObjectError) { groupNode = try appendNode(PredicateNode.group(kind: isAnd ? 1 : 2), parent: parent) }
                        catch { failure = error; return }
                        do throws(WireDecodeError) {
                            try groupReader.withArrayElements { condition in self.appendConditionValue(condition, parent: groupNode, failure: &failure) }
                        } catch { failure = ObjectError(.invalidPredicateExpression) }
                    }
                }
            }
        } catch { failure = ObjectError(.invalidPredicateExpression) }
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

    private mutating func appendExpressionValue(_ bytes: ByteSlice, failure: inout ObjectError?) -> (operation: ObjectPredicateOperator, operand: Int, count: Int)? {
        let value = WireValueReader(bytes)
        guard value.kind == .array else { failure = ObjectError(.invalidPredicateExpression); return nil }
        var operation: ObjectPredicateOperator?
        var operandIndexes = InlineArray<2, Int>(repeating: -1)
        var operandCount = 0
        do throws(WireDecodeError) {
            try value.withArrayElements { element in
                if operandCount == 0 { operation = parseOperator(element) }
                else if operandCount <= 2 { operandIndexes[operandCount - 1] = self.appendLiteralValue(element, failure: &failure) ?? -1 }
                else { failure = ObjectError(.invalidPredicateExpression) }
                operandCount += 1
            }
        } catch { failure = ObjectError(.invalidPredicateExpression) }
        guard failure == nil, let operation else { failure = ObjectError(.invalidPredicateExpression); return nil }
        let expected: Int
        switch operation { case .exists, .notExists: expected = 1; case .between, .notBetween: expected = 3; default: expected = 2 }
        guard operandCount == expected else { failure = ObjectError(.invalidPredicateExpression); return nil }
        if operation == .exists || operation == .notExists { return (operation, 0, 0) }
        let firstIndex = operandIndexes[0]
        guard firstIndex >= 0 else { failure = ObjectError(.invalidPredicateExpression); return nil }
        if operation == .between || operation == .notBetween {
            guard operandIndexes[1] == firstIndex + 1 else { failure = ObjectError(.invalidPredicateExpression); return nil }
        }
        if operation == .valuesIn || operation == .valuesNotIn, !literalIsArray(firstIndex) { failure = ObjectError(.invalidPredicateExpression); return nil }
        return (operation, firstIndex, operation == .between || operation == .notBetween ? 2 : 1)
    }

    private func parseOperator(_ bytes: ByteSlice) -> ObjectPredicateOperator? {
        guard bytes.length > 0 else { return nil }
        var value = 0
        for index in 0..<bytes.length {
            guard let byte = bytes.byte(at: index), byte >= 48 && byte <= 57 else { return nil }
            let (next, overflow) = value.multipliedReportingOverflow(by: 10)
            let (result, digitOverflow) = next.addingReportingOverflow(Int(byte - 48))
            guard !overflow && !digitOverflow else { return nil }
            value = result
        }
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

    private mutating func appendPathValue(_ value: ByteSlice, failure: inout ObjectError?) -> Int? {
        guard pathCount < pathCapacity else { failure = ObjectError(.capacityExceeded); return nil }
        let pathIndex = pathCount; pathCount += 1
        let first = segmentsCount; var segmentCount = 0
        let reader = WireValueReader(value)
        if reader.kind == .string {
            let content = value.subSlice(from: 1, length: max(0, value.length - 2))
            var start = 0
            for index in 0...content.length {
                if index == content.length || content.byte(at: index) == 46 {
                    guard index > start else { failure = ObjectError(.invalidPredicatePath); return nil }
                    appendSegment(content, start: start, length: index - start, failure: &failure)
                    segmentCount += 1; start = index + 1
                }
            }
        } else if reader.kind == .array {
            do throws(WireDecodeError) { try reader.withArrayElements { segment in
                guard WireValueReader(segment).kind == .string, segment.length >= 2 else { failure = ObjectError(.invalidPredicatePath); return }
                appendSegment(segment, start: 1, length: segment.length - 2, failure: &failure); segmentCount += 1
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

    private mutating func appendSegment(_ value: ByteSlice, start: Int, length: Int, failure: inout ObjectError?) {
        guard failure == nil, arenaLength + length <= arenaCapacity else { failure = ObjectError(.capacityExceeded); return }
        guard segmentsCount < pathCapacity else { failure = ObjectError(.capacityExceeded); return }
        let segmentIndex = segmentsCount
        for index in 0..<length { arena[arenaLength + index] = value.byte(at: start + index)! }
        segments[segmentIndex] = PredicateSegment(start: arenaLength, length: length)
        arenaLength += length
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
            guard WireReader.isValidJSONValue(bytes), WireValueReader(bytes).kind == .number else { throw ObjectError(.invalidPredicateExpression) }
            try copy(bytes)
        }
        literals[literalCount] = PredicateLiteral(start: start, length: arenaLength - start)
        literalCount += 1
        return literalCount - 1
    }

    private mutating func appendLiteralValue(_ value: ByteSlice, failure: inout ObjectError?) -> Int? {
        do throws(ObjectError) { return try appendLiteral(.raw(value)) } catch { failure = error; return nil }
    }

    private mutating func copy(_ value: ByteSlice) throws(ObjectError) {
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

    private borrowing func literalIsArray(_ index: Int) -> Bool { literalSlice(index) { WireValueReader($0).kind == .array } }

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
        if node.kind == .condition { return evaluateCondition(node, fields: fields) }
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
                        ? body(raw, WireValueReader(raw).kind)
                        : resolveNested(raw, path: path, segment: segment + 1, body)
                }
            }
            return found
        }
    }

    private borrowing func resolveNested(_ raw: ByteSlice, path: PredicatePath, segment: Int, _ body: (ByteSlice, WireValueKind) -> Bool) -> Bool {
        let reader = WireValueReader(raw)
        guard reader.kind == .object else { return false }
        var result = false
        do throws(WireDecodeError) { try reader.withObjectFields { field in
            field.withKey { key in
                _ = withSegment(path, segment) { wanted in
                    guard key.semanticEquals(wanted) else { return false }
                    field.withValue { child in result = resolveNestedValue(child, path: path, segment: segment, body) }
                    return result
                }
            }
        }} catch { return false }
        return result
    }

    private borrowing func resolveNestedValue(_ raw: ByteSlice, path: PredicatePath, segment: Int, _ body: (ByteSlice, WireValueKind) -> Bool) -> Bool {
        if segment + 1 == path.segmentCount { return body(raw, WireValueReader(raw).kind) }
        return resolveNested(raw, path: path, segment: segment + 1, body)
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
        case .equals: return literalSlice(operand) { jsonEqual(raw, $0) }
        case .notEquals: return literalSlice(operand) { !jsonEqual(raw, $0) }
        case .contains: return literalSlice(operand) { jsonContains(raw, $0) }
        case .notContains: return literalSlice(operand) { !jsonContains(raw, $0) }
        case .valuesIn: return literalSlice(operand) { jsonIn(raw, $0) }
        case .valuesNotIn: return literalSlice(operand) { !jsonIn(raw, $0) }
        case .like: return literalSlice(operand) { wildcard(raw, $0) }
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return literalSlice(operand) { compare(raw, $0, operation) }
        case .between, .notBetween:
            var inside = false
            literalSlice(operand) { first in
            literalSlice(operand + 1) { second in
                if compareNumbers(first, second) <= 0 {
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
        if WireValueReader(lhs).kind == .number && WireValueReader(rhs).kind == .number { result = compareNumbers(lhs, rhs) }
        else if WireValueReader(lhs).kind == .string && WireValueReader(rhs).kind == .string { result = compareStrings(lhs, rhs) }
        else { return false }
        switch operation { case .lessThan: return result < 0; case .lessThanOrEqual: return result <= 0; case .greaterThan: return result > 0; case .greaterThanOrEqual: return result >= 0; default: return false }
    }

    private func compareStrings(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Int {
        // WireReader's measured maximum payload is 512 bytes. Overflow is a
        // deterministic non-match, never silent truncation.
        var left = InlineArray<512, UInt32>(repeating: 0)
        var right = InlineArray<512, UInt32>(repeating: 0)
        var lc = 0; var rc = 0; var overflow = false
        try? WireValueReader(lhs).withStringScalars { if lc < PredicateScratchLimits.scalarCapacity { left[lc] = $0; lc += 1 } else { overflow = true } }
        try? WireValueReader(rhs).withStringScalars { if rc < PredicateScratchLimits.scalarCapacity { right[rc] = $0; rc += 1 } else { overflow = true } }
        guard !overflow else { return 0 }
        for index in 0..<min(lc, rc) where left[index] != right[index] { return left[index] < right[index] ? -1 : 1 }
        return lc == rc ? 0 : (lc < rc ? -1 : 1)
    }

    private func compareNumbers(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Int {
        // Exact decimal ordering without converting through Double. The bounded
        // raw lexemes are compared after sign, leading-zero, and exponent removal.
        let left = DecimalParts(lhs); let right = DecimalParts(rhs)
        if left.zero && right.zero { return 0 }
        if left.negative != right.negative { return left.negative ? -1 : 1 }
        let sign = left.negative ? -1 : 1
        if left.position != right.position { return left.position < right.position ? -sign : sign }
        let count = max(left.count, right.count)
        for index in 0..<count { if left.digit(at: index) != right.digit(at: index) { return left.digit(at: index) < right.digit(at: index) ? -sign : sign } }
        return 0
    }

    private func jsonEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        let left = WireValueReader(lhs).kind; let right = WireValueReader(rhs).kind
        if left == .number && right == .number { return compareNumbers(lhs, rhs) == 0 }
        if left != right { return false }
        if left == .string { return scalarEqual(lhs, rhs) }
        if left == .object { return objectEqual(lhs, rhs) }
        if left == .array { return arrayEqual(lhs, rhs) }
        return lhs == rhs
    }

    private func objectEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var leftCount = 0; var result = true
        do throws(WireDecodeError) { try WireValueReader(lhs).withObjectFields { left in
            leftCount += 1; var found = false
            left.withKey { key in
                do throws(WireDecodeError) { try WireValueReader(rhs).withObjectFields { right in right.withKey { rightKey in if key.semanticEquals(rightKey) { right.withValue { rv in left.withValue { lv in found = jsonEqual(lv, rv) } } } } } } catch { result = false }
            }
            if !found { result = false }
        }; if result { var rightCount = 0; try WireValueReader(rhs).withObjectFields { _ in rightCount += 1 }; if rightCount != leftCount { result = false } } } catch { return false }
        return result
    }

    private func arrayEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var index = 0; var result = true
        do throws(WireDecodeError) { try WireValueReader(lhs).withArrayElements { element in
            if !arrayElementEquals(rhs, at: index, to: element) { result = false }; index += 1
        }; if arrayHasElement(rhs, at: index) { result = false } } catch { return false }
        return result
    }

    private func jsonContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        let leftKind = WireValueReader(lhs).kind; let rightKind = WireValueReader(rhs).kind
        if leftKind == .string && rightKind == .string { return stringContains(lhs, rhs) }
        if leftKind == .object && rightKind == .object { return objectContains(lhs, rhs) }
        if leftKind == .array {
            if rightKind == .array {
                var result = true; do throws(WireDecodeError) { try WireValueReader(rhs).withArrayElements { requested in if !arrayContains(lhs, requested) { result = false } } } catch { return false }; return result
            }
            return arrayContains(lhs, rhs)
        }
        return jsonEqual(lhs, rhs)
    }

    private func objectContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        var result = true
        do throws(WireDecodeError) { try WireValueReader(rhs).withObjectFields { wanted in wanted.withKey { key in var found = false; try? WireValueReader(lhs).withObjectFields { candidate in candidate.withKey { candidateKey in if key.semanticEquals(candidateKey) { candidate.withValue { cv in wanted.withValue { wv in found = jsonContains(cv, wv) } } } } }; if !found { result = false } } } } catch { return false }
        return result
    }

    private func arrayContains(_ lhs: ByteSlice, _ wanted: ByteSlice) -> Bool {
        var found = false; try? WireValueReader(lhs).withArrayElements { candidate in if jsonEqual(candidate, wanted) { found = true } }; return found
    }

    private func jsonIn(_ value: ByteSlice, _ values: ByteSlice) -> Bool {
        var found = false; try? WireValueReader(values).withArrayElements { candidate in if jsonEqual(value, candidate) { found = true } }; return found
    }

    private func arrayElementEquals(_ value: ByteSlice, at target: Int, to wanted: ByteSlice) -> Bool {
        var index = 0; var result = false
        try? WireValueReader(value).withArrayElements { element in if index == target { result = jsonEqual(element, wanted) }; index += 1 }
        return result
    }

    private func arrayHasElement(_ value: ByteSlice, at target: Int) -> Bool {
        var index = 0; var result = false
        try? WireValueReader(value).withArrayElements { _ in if index == target { result = true }; index += 1 }
        return result
    }

    private func scalarEqual(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool {
        // The same 512-byte wire bound is the scalar scratch bound.
        var left = InlineArray<512, UInt32>(repeating: 0); var right = InlineArray<512, UInt32>(repeating: 0); var lc = 0; var rc = 0; var overflow = false
        try? WireValueReader(lhs).withStringScalars { if lc < PredicateScratchLimits.scalarCapacity { left[lc] = $0; lc += 1 } else { overflow = true } }; try? WireValueReader(rhs).withStringScalars { if rc < PredicateScratchLimits.scalarCapacity { right[rc] = $0; rc += 1 }
            else { overflow = true }
        }; guard lc == rc else { return false }; for i in 0..<lc where left[i] != right[i] { return false }; return true
    }

    private func stringContains(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Bool { wildcardMatch(lhs, rhs, like: false) }

    private func wildcard(_ value: ByteSlice, _ pattern: ByteSlice) -> Bool { wildcardMatch(value, pattern, like: true) }

    private func wildcardMatch(_ value: ByteSlice, _ pattern: ByteSlice, like: Bool) -> Bool {
        var text = InlineArray<512, UInt32>(repeating: 0); var pat = InlineArray<512, UInt32>(repeating: 0); var tc = 0; var pc = 0; var overflow = false
        try? WireValueReader(value).withStringScalars { if tc < PredicateScratchLimits.scalarCapacity { text[tc] = $0; tc += 1 } else { overflow = true } }; try? WireValueReader(pattern).withStringScalars { if pc < PredicateScratchLimits.scalarCapacity { pat[pc] = $0; pc += 1 } else { overflow = true } }
        guard !overflow else { return false }
        if !like {
            if pc == 0 { return true }
            for start in 0...tc where start + pc <= tc {
                var ok = true
                for i in 0..<pc where text[start + i] != pat[i] { ok = false }
                if ok { return true }
            }
            return false
        }
        var ti = 0; var pi = 0; var star = -1; var mark = 0
        while ti < tc {
            // Coaty LIKE uses backslash as the escape character. The wire
            // decoder intentionally leaves that scalar in the pattern, so a
            // JSON `\\\\%` sequence reaches this branch as `\\%` and the
            // percent is matched literally rather than becoming a wildcard.
            if like, pi + 1 < pc, pat[pi] == 0x5C {
                if pat[pi + 1] == text[ti] { ti += 1; pi += 2; continue }
            } else if pi < pc && (pat[pi] == text[ti] || pat[pi] == 0x5F) {
                ti += 1; pi += 1; continue
            } else if like, pi < pc, pat[pi] == 0x25 {
                star = pi; pi += 1; mark = ti; continue
            }
            if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < pc {
            if like, pi + 1 < pc, pat[pi] == 0x5C { return false }
            guard like, pat[pi] == 0x25 else { return false }
            pi += 1
        }
        return true
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
private struct PredicateLiteral { var start = 0; var length = 0 }

private struct DecimalParts {
    let raw: ByteSlice
    let negative: Bool
    let zero: Bool
    let position: Int
    let count: Int
    init(_ raw: ByteSlice) {
        self.raw = raw; negative = raw.byte(at: 0) == 45
        var index = negative ? 1 : 0; var digitsBeforeDecimal = 0; var digitOrdinal = 0; var leading = true; var significant = 0; var firstSignificant = 0
        while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 { if byte != 48 && leading { leading = false; firstSignificant = digitOrdinal }; if !leading { significant += 1 }; digitOrdinal += 1; digitsBeforeDecimal += 1; index += 1 }
        if index < raw.length && raw.byte(at: index) == 46 { index += 1; while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 { if byte != 48 && leading { leading = false; firstSignificant = digitOrdinal }; if !leading { significant += 1 }; digitOrdinal += 1; index += 1 } }
        var exponent = 0; var exponentNegative = false
        if index < raw.length && (raw.byte(at: index) == 101 || raw.byte(at: index) == 69) { index += 1; if raw.byte(at: index) == 45 { exponentNegative = true; index += 1 } else if raw.byte(at: index) == 43 { index += 1 }; while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 { exponent = exponent > 100_000 ? 1_000_000 : min(1_000_000, exponent * 10 + Int(byte - 48)); index += 1 } }
        let hasDigits = significant > 0; zero = !hasDigits; count = significant; position = hasDigits ? digitsBeforeDecimal - firstSignificant + (exponentNegative ? -exponent : exponent) : 0
    }
    func digit(at index: Int) -> UInt8 { var seen = 0; var started = false; for i in 0..<raw.length { let b = raw.byte(at: i)!; if b == 101 || b == 69 { break }; if b >= 48 && b <= 57 { if b != 48 { started = true }; if started { if seen == index { return b - 48 }; seen += 1 } } }; return 0 }
}
