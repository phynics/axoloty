// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// The comparison seam used by predicate evaluation for exact JSON numbers.
enum PredicateDecimalComparison {
    static func compare(_ lhs: ByteSlice, _ rhs: ByteSlice) -> Int? {
        // Exact decimal ordering without converting through Double. The bounded
        // raw lexemes are compared after sign, leading-zero, and exponent removal.
        let left = DecimalParts(lhs); let right = DecimalParts(rhs)
        guard left.valid && right.valid else { return nil }
        if left.zero && right.zero { return 0 }
        if left.negative != right.negative { return left.negative ? -1 : 1 }
        let sign = left.negative ? -1 : 1
        let positionComparison = left.position.compare(to: right.position)
        if positionComparison != 0 { return positionComparison < 0 ? -sign : sign }
        let count = max(left.count, right.count)
        for index in 0..<count {
            if left.digit(at: index) != right.digit(at: index) {
                return left.digit(at: index) < right.digit(at: index) ? -sign : sign
            }
        }
        return 0
    }
}

/// A signed decimal integer backed by the same bounded byte budget as a wire
/// value. It keeps exponent ordering exact without converting through Int or
/// Double; only the small significand-position offset is added arithmetically.
private struct BigSignedDecimal {
    private var digits: InlineArray<512, UInt8>
    private var count: Int
    private var negative: Bool

    init(raw: ByteSlice, start: Int, end: Int, negative: Bool) {
        digits = InlineArray(repeating: 0)
        count = 0
        self.negative = false
        guard start >= 0, end <= raw.length, start < end else { return }
        var first = start
        while first < end, raw.byte(at: first) == 48 { first += 1 }
        guard first < end else { return }
        count = end - first
        for index in 0..<count { digits[index] = raw.byte(at: end - 1 - index)! - 48 }
        self.negative = negative
    }

    mutating func add(_ offset: Int) -> Bool {
        guard offset != 0 else { return true }
        let amountNegative = offset < 0
        let amount = amountNegative ? -offset : offset
        guard count > 0 else {
            setSmall(amount)
            negative = amountNegative
            return true
        }
        guard negative == amountNegative else {
            let magnitudeComparison = compareMagnitude(to: amount)
            if magnitudeComparison == 0 {
                count = 0
                negative = false
            } else if magnitudeComparison > 0 {
                subtractSmall(amount)
            } else {
                replaceWithSmallMinusSelf(amount)
                negative = amountNegative
            }
            return true
        }
        return addSmall(amount)
    }

    func compare(to other: BigSignedDecimal) -> Int {
        if negative != other.negative { return negative ? -1 : 1 }
        if count != other.count {
            let result = count < other.count ? -1 : 1
            return negative ? -result : result
        }
        guard count > 0 else { return 0 }
        for index in stride(from: count - 1, through: 0, by: -1) where digits[index] != other.digits[index] {
            let result = digits[index] < other.digits[index] ? -1 : 1
            return negative ? -result : result
        }
        return 0
    }

    private mutating func setSmall(_ value: Int) {
        count = 0
        var remaining = value
        while remaining > 0 { digits[count] = UInt8(remaining % 10); count += 1; remaining /= 10 }
    }

    private func smallCount(_ value: Int) -> Int {
        var remaining = value
        var result = 0
        while remaining > 0 { result += 1; remaining /= 10 }
        return result
    }

    private func compareMagnitude(to value: Int) -> Int {
        let valueCount = smallCount(value)
        if count != valueCount { return count < valueCount ? -1 : 1 }
        guard count > 0 else { return 0 }
        var remaining = value
        for index in stride(from: count - 1, through: 0, by: -1) {
            let digit = UInt8(remaining % 10)
            if digits[index] != digit { return digits[index] < digit ? -1 : 1 }
            remaining /= 10
        }
        return 0
    }

    private mutating func addSmall(_ value: Int) -> Bool {
        var remaining = value
        var index = 0
        while remaining > 0 || index < count {
            guard index < 512 else { return false }
            let sum = Int(digits[index]) + (remaining % 10) + (index < count ? 0 : 0)
            digits[index] = UInt8(sum % 10)
            let carry = sum / 10
            remaining = remaining / 10 + carry
            index += 1
            if index == count && remaining > 0 { count += 1 }
        }
        return true
    }

    private mutating func subtractSmall(_ value: Int) {
        var remaining = value
        var borrow = 0
        for index in 0..<count {
            let difference = Int(digits[index]) - (remaining % 10) - borrow
            remaining /= 10
            if difference < 0 { digits[index] = UInt8(difference + 10); borrow = 1 } else { digits[index] = UInt8(difference); borrow = 0 }
            if remaining == 0 && borrow == 0 { break }
        }
        while count > 0 && digits[count - 1] == 0 { count -= 1 }
        if count == 0 { negative = false }
    }

    private mutating func replaceWithSmallMinusSelf(_ value: Int) {
        let old = digits
        let oldCount = count
        var result = InlineArray<512, UInt8>(repeating: 0)
        var remaining = value
        var borrow = 0
        count = max(oldCount, smallCount(value))
        for index in 0..<count {
            let difference = (remaining % 10) - (index < oldCount ? Int(old[index]) : 0) - borrow
            remaining /= 10
            if difference < 0 { result[index] = UInt8(difference + 10); borrow = 1 } else { result[index] = UInt8(difference); borrow = 0 }
        }
        digits = result
        while count > 0 && digits[count - 1] == 0 { count -= 1 }
        if count == 0 { negative = false }
    }
}

private struct DecimalParts {
    let raw: ByteSlice
    let negative: Bool
    let zero: Bool
    let valid: Bool
    let position: BigSignedDecimal
    let count: Int

    init(_ raw: ByteSlice) {
        let isNegative = raw.byte(at: 0) == 45
        self.raw = raw
        self.negative = isNegative
        var index = isNegative ? 1 : 0
        var digitsBeforeDecimal = 0
        var digitOrdinal = 0
        var leading = true
        var significant = 0
        var firstSignificant = 0
        while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 {
            if byte != 48 && leading { leading = false; firstSignificant = digitOrdinal }
            if !leading { significant += 1 }
            digitOrdinal += 1; digitsBeforeDecimal += 1; index += 1
        }
        if index < raw.length && raw.byte(at: index) == 46 {
            index += 1
            while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 {
                if byte != 48 && leading { leading = false; firstSignificant = digitOrdinal }
                if !leading { significant += 1 }
                digitOrdinal += 1; index += 1
            }
        }
        var exponentStart = -1
        var exponentEnd = -1
        var exponentNegative = false
        if index < raw.length && (raw.byte(at: index) == 101 || raw.byte(at: index) == 69) {
            index += 1
            if raw.byte(at: index) == 45 { exponentNegative = true; index += 1 }
            else if raw.byte(at: index) == 43 { index += 1 }
            exponentStart = index
            while index < raw.length, let byte = raw.byte(at: index), byte >= 48 && byte <= 57 { index += 1 }
            exponentEnd = index
        }
        var adjustedPosition = BigSignedDecimal(raw: raw, start: exponentStart, end: exponentEnd, negative: exponentNegative)
        let positionValid = significant == 0 || adjustedPosition.add(digitsBeforeDecimal - firstSignificant)
        self.zero = significant == 0
        self.valid = positionValid
        self.count = significant
        self.position = adjustedPosition
    }

    func digit(at index: Int) -> UInt8 {
        var seen = 0
        var started = false
        for i in 0..<raw.length {
            let b = raw.byte(at: i)!
            if b == 101 || b == 69 { break }
            if b >= 48 && b <= 57 {
                if b != 48 { started = true }
                if started {
                    if seen == index { return b - 48 }
                    seen += 1
                }
            }
        }
        return 0
    }
}
