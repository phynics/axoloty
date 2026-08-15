// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

    @usableFromInline struct WireFieldSlot {
        let key: Range<Int>; let value: Range<Int>; let content: Range<Int>; let kind: WireTokenKind
    }

    @usableFromInline struct WireFieldIndex {
        var rootObject = false; var completeValue = false; var failure: WireDecodeError?; var count = 0
        var slots = (WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none, WireFieldSlot?.none)
        func slot(_ n: Int) -> WireFieldSlot? {
            switch n {
            case 0...7: return firstSlot(n)
            case 8...15: return secondSlot(n)
            case 16...23: return thirdSlot(n)
            default: return nil
            }
        }

        private func firstSlot(_ n: Int) -> WireFieldSlot? {
            switch n {
            case 0: return slots.0; case 1: return slots.1; case 2: return slots.2; case 3: return slots.3
            case 4: return slots.4; case 5: return slots.5; case 6: return slots.6; case 7: return slots.7
            default: return nil
            }
        }

        private func secondSlot(_ n: Int) -> WireFieldSlot? {
            switch n {
            case 8: return slots.8; case 9: return slots.9; case 10: return slots.10; case 11: return slots.11
            case 12: return slots.12; case 13: return slots.13; case 14: return slots.14; case 15: return slots.15
            default: return nil
            }
        }

        private func thirdSlot(_ n: Int) -> WireFieldSlot? {
            switch n {
            case 16: return slots.16; case 17: return slots.17; case 18: return slots.18; case 19: return slots.19
            case 20: return slots.20; case 21: return slots.21; case 22: return slots.22; case 23: return slots.23
            default: return nil
            }
        }
        func find(bytes: UnsafeRawPointer, key: StaticString) -> WireFieldSlot? {
            for n in 0..<count {
                guard let value = slot(n) else { continue }
                if wireSemanticKeysEqual(bytes: bytes, range: value.key, key: key) { return value }
            }
            return nil
        }
    mutating func append(_ value: WireFieldSlot, bytes: UnsafeBufferPointer<UInt8>) {
        guard validRanges(for: value, bytes: bytes) else {
            if failure == nil { failure = WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count) }
            return
        }
        guard !hasDuplicate(value, bytes: bytes) else {
            if failure == nil { failure = WireDecodeError(.duplicateField, byteOffset: value.key.lowerBound) }
            return
        }
        guard count < WireBufferConfig.maxIndexedFields else {
            failure = WireDecodeError(.fieldIndexOverflow, byteOffset: value.key.lowerBound)
            return
        }
        store(value)
        count += 1
    }

    private func validRanges(for value: WireFieldSlot, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        isBounded(value.key, bytes: bytes) && isBounded(value.value, bytes: bytes) && isBounded(value.content, bytes: bytes)
    }

    private func hasDuplicate(_ value: WireFieldSlot, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for n in 0..<count where slot(n).map({ wireSemanticKeysEqual(bytes: bytes, lhs: $0.key, rhs: value.key) }) == true {
            return true
        }
        return false
    }

    private mutating func store(_ value: WireFieldSlot) {
        switch count {
        case 0...7: storeFirst(value)
        case 8...15: storeSecond(value)
        case 16...23: storeThird(value)
        default: break
        }
    }

    private mutating func storeFirst(_ value: WireFieldSlot) {
        switch count {
        case 0: slots.0 = value; case 1: slots.1 = value; case 2: slots.2 = value; case 3: slots.3 = value
        case 4: slots.4 = value; case 5: slots.5 = value; case 6: slots.6 = value; case 7: slots.7 = value
        default: break
        }
    }

    private mutating func storeSecond(_ value: WireFieldSlot) {
        switch count {
        case 8: slots.8 = value; case 9: slots.9 = value; case 10: slots.10 = value; case 11: slots.11 = value
        case 12: slots.12 = value; case 13: slots.13 = value; case 14: slots.14 = value; case 15: slots.15 = value
        default: break
        }
    }

    private mutating func storeThird(_ value: WireFieldSlot) {
        switch count {
        case 16: slots.16 = value; case 17: slots.17 = value; case 18: slots.18 = value; case 19: slots.19 = value
        case 20: slots.20 = value; case 21: slots.21 = value; case 22: slots.22 = value; case 23: slots.23 = value
        default: break
        }
    }
        private func isBounded(_ range: Range<Int>, bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            range.lowerBound >= 0 && range.lowerBound <= range.upperBound && range.upperBound <= bytes.count
        }
    }

    struct WireTokenContext { let start: Int; let key: Range<Int>? }
    struct WireFieldDestination: JSONTokenizerDestination {
        typealias ArrayStartContext = WireTokenContext; typealias ObjectStartContext = WireTokenContext
        let bytes: UnsafeBufferPointer<UInt8>
        var index = WireFieldIndex()
        var depth = 0
        var pendingKey: Range<Int>?
        var expectingKey = false
        var containerCount = 0
        var containers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))

        mutating func objectStartFound(_ token: JSONToken.ObjectStart) -> WireTokenContext {
            if depth == 0 { index.rootObject = true; expectingKey = true }
            if depth >= 8 { record(.init(.invalidNesting, byteOffset: token.start.byteOffset)) }
            pushContainer(0x7B)
            let context = WireTokenContext(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil)
            pendingKey = nil
            depth += 1
            return context
        }

        mutating func objectEndFound(_ token: JSONToken.ObjectEnd, context: consuming WireTokenContext) {
            depth -= 1
            popContainer()
            if depth == 1, let key = context.key {
                index.append(WireFieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .object), bytes: bytes)
                expectingKey = true
            }
            if depth == 0 { index.completeValue = true; expectingKey = false }
        }

        mutating func arrayStartFound(_ token: JSONToken.ArrayStart) -> WireTokenContext {
            if depth >= 8 { record(.init(.invalidNesting, byteOffset: token.start.byteOffset)) }
            pushContainer(0x5B)
            let context = WireTokenContext(start: token.start.byteOffset, key: depth == 1 ? pendingKey : nil)
            pendingKey = nil
            depth += 1
            return context
        }

        mutating func arrayEndFound(_ token: JSONToken.ArrayEnd, context: consuming WireTokenContext) {
            depth -= 1
            popContainer()
            if depth == 1, let key = context.key {
                index.append(WireFieldSlot(key: key, value: context.start..<token.end.byteOffset, content: context.start..<token.end.byteOffset, kind: .array), bytes: bytes)
                expectingKey = true
            }
            if depth == 0 { index.completeValue = true }
        }

        mutating func stringFound(_ token: JSONToken.String) {
            let raw = token.start.byteOffset..<token.end.byteOffset
            if let failure = validateString(raw) { record(failure) }
            let content = raw.lowerBound < raw.upperBound && bytes[raw.lowerBound] == 0x22 ? raw.lowerBound + 1..<raw.upperBound - 1 : raw
            if depth == 1 && expectingKey { pendingKey = content; expectingKey = false }
            else { value(raw, content, .string) }
        }

        mutating func numberFound(_ token: JSONToken.Number) {
            let raw = token.start.byteOffset..<token.end.byteOffset
            if let failure = validateNumber(raw) { record(failure) }
            value(raw, raw, .number)
        }

        mutating func booleanTrueFound(_ token: JSONToken.BooleanTrue) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .trueValue) }
        mutating func booleanFalseFound(_ token: JSONToken.BooleanFalse) { let raw = token.start.byteOffset - 5..<token.start.byteOffset; value(raw, raw, .falseValue) }
        mutating func nullFound(_ token: JSONToken.Null) { let raw = token.start.byteOffset - 4..<token.start.byteOffset; value(raw, raw, .nullValue) }

        mutating func value(_ raw: Range<Int>, _ content: Range<Int>, _ kind: WireTokenKind) {
            if depth == 0 { index.completeValue = true; return }
            guard depth == 1, let key = pendingKey else { return }
            index.append(WireFieldSlot(key: key, value: raw, content: content, kind: kind), bytes: bytes)
            pendingKey = nil
            expectingKey = true
            index.completeValue = true
        }

        mutating func record(_ error: WireDecodeError) {
            if index.failure == nil { index.failure = error }
        }

        mutating func pushContainer(_ kind: UInt8) {
            switch containerCount {
            case 0: containers.0 = kind
            case 1: containers.1 = kind
            case 2: containers.2 = kind
            case 3: containers.3 = kind
            case 4: containers.4 = kind
            case 5: containers.5 = kind
            case 6: containers.6 = kind
            case 7: containers.7 = kind
            default: break
            }
            containerCount += 1
        }

        mutating func popContainer() {
            if containerCount > 0 { containerCount -= 1 }
        }

        var topContainer: UInt8? {
            switch containerCount {
            case 1: containers.0
            case 2: containers.1
            case 3: containers.2
            case 4: containers.3
            case 5: containers.4
            case 6: containers.5
            case 7: containers.6
            case 8: containers.7
            default: nil
            }
        }

    func validateString(_ range: Range<Int>) -> WireDecodeError? {
        guard range.count >= 2 else { return .init(.unexpectedEndOfInput, byteOffset: range.lowerBound) }
        let end = range.upperBound - 1
        var offset = range.lowerBound + 1
        while offset < end {
            let byte = bytes[offset]
            if byte == 0x5C {
                if let failure = validateEscape(at: &offset, before: end) { return failure }
            } else if byte < 0x20 {
                return .init(.invalidEscape, byteOffset: offset)
            } else {
                guard let width = utf8Width(byte) else { return .init(.invalidUTF8, byteOffset: offset) }
                if let failure = validateUTF8(at: offset, width: width, before: end) { return failure }
                offset += width
            }
        }
        return nil
    }

    private func validateEscape(at offset: inout Int, before end: Int) -> WireDecodeError? {
        let escapeOffset = offset
        offset += 1
        guard offset < end else { return .init(.invalidEscape, byteOffset: escapeOffset) }
        if bytes[offset] == 0x75 { return validateUnicodeEscape(at: &offset, before: end, escapeOffset: escapeOffset) }
        switch bytes[offset] {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
            offset += 1
            return nil
        default:
            return .init(.invalidEscape, byteOffset: offset)
        }
    }

    private func validateUnicodeEscape(
        at offset: inout Int, before end: Int, escapeOffset: Int
    ) -> WireDecodeError? {
        guard let high = unicodeEscape(at: offset, before: end) else {
            return .init(.invalidEscape, byteOffset: offset)
        }
        offset += 5
        if high >= 0xD800 && high <= 0xDBFF {
            guard offset + 5 < end, bytes[offset] == 0x5C, bytes[offset + 1] == 0x75,
                  let low = unicodeEscape(at: offset + 1, before: end), low >= 0xDC00, low <= 0xDFFF
            else { return .init(.invalidEscape, byteOffset: escapeOffset) }
            offset += 6
        } else if high >= 0xDC00 && high <= 0xDFFF {
            return .init(.invalidEscape, byteOffset: escapeOffset)
        }
        return nil
    }

    private func utf8Width(_ byte: UInt8) -> Int? {
        switch byte {
        case 0..<0x80: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    private func validateUTF8(at offset: Int, width: Int, before end: Int) -> WireDecodeError? {
        guard offset + width <= end else { return .init(.invalidUTF8, byteOffset: offset) }
        if width > 1 {
            let second = bytes[offset + 1]
            guard validUTF8Boundary(bytes[offset], second: second) else {
                return .init(.invalidUTF8, byteOffset: offset)
            }
            for continuation in 1..<width where bytes[offset + continuation] < 0x80 || bytes[offset + continuation] > 0xBF {
                return .init(.invalidUTF8, byteOffset: offset + continuation)
            }
        }
        return nil
    }

    private func validUTF8Boundary(_ first: UInt8, second: UInt8) -> Bool {
        !((first == 0xE0 && second < 0xA0) || (first == 0xED && second > 0x9F) ||
          (first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F))
    }

    func unicodeEscape(at offset: Int, before end: Int) -> Int? {
        guard offset + 4 < end else { return nil }
        var value = 0
        for digitOffset in 1...4 {
            let byte = bytes[offset + digitOffset]
            let digit: Int
            if byte >= 48 && byte <= 57 { digit = Int(byte - 48) }
            else if byte >= 65 && byte <= 70 { digit = Int(byte - 55) }
            else if byte >= 97 && byte <= 102 { digit = Int(byte - 87) }
            else { return nil }
            value = value * 16 + digit
        }
        return value
    }

    func validateNumber(_ range: Range<Int>) -> WireDecodeError? {
        var offset = range.lowerBound
        if bytes[offset] == 0x2D { offset += 1 }
        guard offset < range.upperBound else { return .init(.invalidNumber, byteOffset: range.lowerBound) }
        if let failure = validateIntegerPart(&offset, range: range) { return failure }
        if offset < range.upperBound, bytes[offset] == 0x2E,
           let failure = validateFraction(&offset, range: range) { return failure }
        if offset < range.upperBound, bytes[offset] == 0x65 || (offset < range.upperBound && bytes[offset] == 0x45),
           let failure = validateExponent(&offset, range: range) { return failure }
        return offset == range.upperBound ? nil : .init(.invalidNumber, byteOffset: offset)
    }

    private func validateIntegerPart(_ offset: inout Int, range: Range<Int>) -> WireDecodeError? {
        if bytes[offset] == 0x30 {
            offset += 1
            if offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 {
                return .init(.invalidNumber, byteOffset: offset)
            }
        } else {
            guard bytes[offset] >= 0x31 && bytes[offset] <= 0x39 else {
                return .init(.invalidNumber, byteOffset: offset)
            }
            consumeDigits(&offset, range: range)
        }
        return nil
    }

    private func validateFraction(_ offset: inout Int, range: Range<Int>) -> WireDecodeError? {
        offset += 1
        guard offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 else {
            return .init(.invalidNumber, byteOffset: offset)
        }
        consumeDigits(&offset, range: range)
        return nil
    }

    private func validateExponent(_ offset: inout Int, range: Range<Int>) -> WireDecodeError? {
        offset += 1
        if offset < range.upperBound && (bytes[offset] == 0x2B || bytes[offset] == 0x2D) { offset += 1 }
        guard offset < range.upperBound, bytes[offset] >= 0x30 && bytes[offset] <= 0x39 else {
            return .init(.invalidNumber, byteOffset: offset)
        }
        consumeDigits(&offset, range: range)
        return nil
    }

    private func consumeDigits(_ offset: inout Int, range: Range<Int>) {
        while offset < range.upperBound && bytes[offset] >= 0x30 && bytes[offset] <= 0x39 { offset += 1 }
    }

        var failure: WireDecodeError? {
            get { index.failure }
            set { index.failure = newValue }
        }

    }
