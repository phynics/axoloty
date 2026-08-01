// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import _JSONCore

struct AdapterFailure: Error { enum Reason { case size, lexical, utf8, control, escape, depth, duplicate, number, trailing, parser }
    let reason: Reason; let offset: Int }

struct AdapterResult {
    let sourceID: Range<Int>?; let actorID: Range<Int>?; let route: Range<Int>?
    let updateRate: Range<Int>?; let payload: Range<Int>?; let tokenCount: Int
}

/// Foundation-free, allocation-free bridge. `_JSONCore` remains the only
/// structural parser; the lexical pass never builds or walks a JSON tree.
struct StrictJSONCoreAdapter {
    private let bytes: UnsafeBufferPointer<UInt8>
    private let maxDepth = 8

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func decode() throws(AdapterFailure) -> AdapterResult {
        guard bytes.count <= 512 else { throw AdapterFailure(reason: .size, offset: 512) }
        try lexicalPass()
        var destination = Destination(bytes: bytes, maxDepth: maxDepth)
        var tokenizer = JSONTokenizer(bytes: bytes, destination: destination)
        do { try tokenizer.scanValue() } catch { tokenizer.destination.failure = AdapterFailure(reason: .parser, offset: tokenizer.currentOffset) }
        destination = tokenizer.destination
        if let failure = destination.failure { throw failure }
        var offset = tokenizer.currentOffset
        while offset < bytes.count, isWhitespace(bytes[offset]) { offset += 1 }
        guard offset == bytes.count else { throw AdapterFailure(reason: .trailing, offset: offset) }
        return destination.result
    }

    private mutating func lexicalPass() throws(AdapterFailure) {
        var i = 0; var depth = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 34 { i = try stringEnd(from: i); continue }
            if c == 123 || c == 91 { depth += 1; if depth > maxDepth { throw AdapterFailure(reason: .depth, offset: i) } }
            if c == 125 || c == 93 { if depth > 0 { depth -= 1 } }
            i += 1
        }
    }

    private mutating func stringEnd(from start: Int) throws(AdapterFailure) -> Int {
        var i = start + 1
        while i < bytes.count {
            let c = bytes[i]
            if c == 34 { return i + 1 }
            if c < 0x20 { throw AdapterFailure(reason: .control, offset: i) }
            if c == 92 { i = try escapeEnd(from: i); continue }
            i = try utf8End(from: i)
        }
        throw AdapterFailure(reason: .escape, offset: start)
    }

    private mutating func escapeEnd(from slash: Int) throws(AdapterFailure) -> Int {
        let i = slash + 1; guard i < bytes.count else { throw AdapterFailure(reason: .escape, offset: slash) }
        switch bytes[i] {
        case 34, 92, 47, 98, 102, 110, 114, 116: return i + 1
        case 117:
            guard i + 4 < bytes.count else { throw AdapterFailure(reason: .escape, offset: i) }
            let first = try hex(at: i + 1); let after = i + 5
            if first >= 0xD800 && first <= 0xDBFF {
                guard after + 5 < bytes.count, bytes[after] == 92, bytes[after + 1] == 117 else { throw AdapterFailure(reason: .escape, offset: after) }
                let second = try hex(at: after + 2); guard second >= 0xDC00 && second <= 0xDFFF else { throw AdapterFailure(reason: .escape, offset: after) }; return after + 6
            }
            if first >= 0xDC00 && first <= 0xDFFF { throw AdapterFailure(reason: .escape, offset: i) }
            return after
        default: throw AdapterFailure(reason: .escape, offset: i)
        }
    }

    private func hex(at p: Int) throws(AdapterFailure) -> Int { var value = 0; for j in 0..<4 { let c = bytes[p + j]; let digit: Int; if c >= 48 && c <= 57 { digit = Int(c - 48) } else if c >= 65 && c <= 70 { digit = Int(c - 55) } else if c >= 97 && c <= 102 { digit = Int(c - 87) } else { throw AdapterFailure(reason: .escape, offset: p + j) }; value = value * 16 + digit }; return value }

    private func utf8End(from start: Int) throws(AdapterFailure) -> Int { let c = bytes[start]; let count: Int; if c < 0x80 { count = 1 } else if c >= 0xC2 && c <= 0xDF { count = 2 } else if c >= 0xE0 && c <= 0xEF { count = 3 } else if c >= 0xF0 && c <= 0xF4 { count = 4 } else { throw AdapterFailure(reason: .utf8, offset: start) }; guard start + count <= bytes.count else { throw AdapterFailure(reason: .utf8, offset: start) }; for j in 1..<count where bytes[start + j] < 0x80 || bytes[start + j] > 0xBF { throw AdapterFailure(reason: .utf8, offset: start + j) }; if count == 3 && ((c == 0xE0 && bytes[start + 1] < 0xA0) || (c == 0xED && bytes[start + 1] >= 0xA0)) { throw AdapterFailure(reason: .utf8, offset: start) }; if count == 4 && ((c == 0xF0 && bytes[start + 1] < 0x90) || (c == 0xF4 && bytes[start + 1] >= 0x90)) { throw AdapterFailure(reason: .utf8, offset: start) }; return start + count }
    private func isWhitespace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    private struct Context { let start: Int; let field: UInt8 }
    private struct Destination: JSONTokenizerDestination {
        typealias ArrayStartContext = Context; typealias ObjectStartContext = Context
        let bytes: UnsafeBufferPointer<UInt8>; let maxDepth: Int; var depth = 0; var rootStarted = false; var expectingKey = false; var pending: UInt8 = 0; var failure: AdapterFailure?
        var sourceID: Range<Int>?; var actorID: Range<Int>?; var route: Range<Int>?; var updateRate: Range<Int>?; var payload: Range<Int>?; var seen: UInt8 = 0; var tokenCount = 0
        var result: AdapterResult { AdapterResult(sourceID: sourceID, actorID: actorID, route: route, updateRate: updateRate, payload: payload, tokenCount: tokenCount) }
        mutating func fail(_ reason: AdapterFailure.Reason, _ offset: Int) { if failure == nil { failure = AdapterFailure(reason: reason, offset: offset) } }
        mutating func arrayStartFound(_ x: JSONToken.ArrayStart) -> Context { tokenCount += 1; let field = depth == 1 ? pending : 0; if depth == 1 { pending = 0 }; depth += 1; return Context(start: x.start.byteOffset, field: field) }
        mutating func arrayEndFound(_ x: JSONToken.ArrayEnd, context: consuming Context) { tokenCount += 1; depth -= 1; set(context.field, context.start..<x.end.byteOffset) }
        mutating func objectStartFound(_ x: JSONToken.ObjectStart) -> Context { tokenCount += 1; if depth == 0 { rootStarted = true; expectingKey = true }; let field = depth == 1 ? pending : 0; if depth == 1 { pending = 0 }; depth += 1; return Context(start: x.start.byteOffset, field: field) }
        mutating func objectEndFound(_ x: JSONToken.ObjectEnd, context: consuming Context) { tokenCount += 1; depth -= 1; set(context.field, context.start..<x.end.byteOffset) }
        mutating func booleanTrueFound(_ x: JSONToken.BooleanTrue) { tokenCount += 1; value(x.start.byteOffset..<(x.start.byteOffset + 4)) }
        mutating func booleanFalseFound(_ x: JSONToken.BooleanFalse) { tokenCount += 1; value(x.start.byteOffset..<(x.start.byteOffset + 5)) }
        mutating func nullFound(_ x: JSONToken.Null) { tokenCount += 1; value(x.start.byteOffset..<(x.start.byteOffset + 4)) }
        mutating func stringFound(_ x: JSONToken.String) { tokenCount += 1; let r = x.start.byteOffset..<x.end.byteOffset; if depth == 1 && expectingKey { pending = key(r); expectingKey = false } else { value(r) } }
        mutating func numberFound(_ x: JSONToken.Number) { tokenCount += 1; let r = x.start.byteOffset..<x.end.byteOffset; validateNumber(r); value(r) }
        mutating func value(_ range: Range<Int>) { if depth == 1 { set(pending, range); pending = 0; expectingKey = true } }
        mutating func set(_ field: UInt8, _ range: Range<Int>) { guard field != 0 else { return }; let bit = UInt8(1 << (field - 1)); if seen & bit != 0 { fail(.duplicate, range.lowerBound) }; seen |= bit; switch field { case 1: sourceID = range; case 2: actorID = range; case 3: route = range; case 4: updateRate = range; case 5: payload = range; default: break } }
        func key(_ range: Range<Int>) -> UInt8 { for code: UInt8 in 1...5 where range.count == nameLength(code) { var equal = true; for i in 0..<range.count where bytes[range.lowerBound + i] != nameByte(code, i) { equal = false }; if equal { return code } }; return 0 }
        func nameLength(_ code: UInt8) -> Int { switch code { case 1: return 12; case 2: return 11; case 3: return 18; case 4: return 12; case 5: return 9; default: return 0 } }
        func nameByte(_ code: UInt8, _ offset: Int) -> UInt8 { switch code { case 1: switch offset { case 0, 11: return 34; case 1: return 105; case 2: return 111; case 3: return 83; case 4: return 111; case 5: return 117; case 6: return 114; case 7: return 99; case 8: return 101; case 9: return 73; case 10: return 100; default: return 0 }; case 2: switch offset { case 0, 10: return 34; case 1: return 105; case 2: return 111; case 3: return 65; case 4: return 99; case 5: return 116; case 6: return 111; case 7: return 114; case 8: return 73; case 9: return 100; default: return 0 }; case 3: switch offset { case 0, 17: return 34; case 1: return 97; case 2: return 115; case 3: return 115; case 4: return 111; case 5: return 99; case 6: return 105; case 7: return 97; case 8: return 116; case 9: return 105; case 10: return 110; case 11: return 103; case 12: return 82; case 13: return 111; case 14: return 117; case 15: return 116; case 16: return 101; default: return 0 }; case 4: switch offset { case 0, 11: return 34; case 1: return 117; case 2: return 112; case 3: return 100; case 4: return 97; case 5: return 116; case 6: return 101; case 7: return 82; case 8: return 97; case 9: return 116; case 10: return 101; default: return 0 }; case 5: switch offset { case 0, 8: return 34; case 1: return 112; case 2: return 97; case 3: return 121; case 4: return 108; case 5: return 111; case 6: return 97; case 7: return 100; default: return 0 }; default: return 0 } }
        mutating func validateNumber(_ r: Range<Int>) { var i = r.lowerBound; if bytes[i] == 45 { i += 1 }; if i >= r.upperBound { fail(.number, i); return }; if bytes[i] == 48 { i += 1; if i < r.upperBound && digit(bytes[i]) { fail(.number, i) } } else { guard bytes[i] >= 49 && bytes[i] <= 57 else { fail(.number, i); return }; while i < r.upperBound && digit(bytes[i]) { i += 1 } }; if i < r.upperBound && bytes[i] == 46 { i += 1; guard i < r.upperBound && digit(bytes[i]) else { fail(.number, i); return }; while i < r.upperBound && digit(bytes[i]) { i += 1 } }; if i < r.upperBound && (bytes[i] == 101 || bytes[i] == 69) { i += 1; if i < r.upperBound && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }; guard i < r.upperBound && digit(bytes[i]) else { fail(.number, i); return }; while i < r.upperBound && digit(bytes[i]) { i += 1 } }; if i != r.upperBound { fail(.number, i) } }
        func digit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    }
}
