// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

struct CountingDestination: JSONTokenizerDestination {
    typealias ArrayStartContext = Int
    typealias ObjectStartContext = Int

    var count = 0

    mutating func arrayStartFound(_ start: JSONToken.ArrayStart) -> Int {
        count += 1
        return count
    }

    mutating func arrayEndFound(_ end: JSONToken.ArrayEnd, context: consuming Int) {
        count += 1
    }

    mutating func objectStartFound(_ start: JSONToken.ObjectStart) -> Int {
        count += 1
        return count
    }

    mutating func objectEndFound(_ end: JSONToken.ObjectEnd, context: consuming Int) {
        count += 1
    }

    mutating func booleanTrueFound(_ boolean: JSONToken.BooleanTrue) { count += 1 }
    mutating func booleanFalseFound(_ boolean: JSONToken.BooleanFalse) { count += 1 }
    mutating func nullFound(_ null: JSONToken.Null) { count += 1 }
    mutating func stringFound(_ string: JSONToken.String) { count += 1 }
    mutating func numberFound(_ number: JSONToken.Number) { count += 1 }
}

func validJSON(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
    let input = UnsafeBufferPointer(start: bytes, count: count)
    var tokenizer = JSONTokenizer(bytes: input, destination: CountingDestination())
    do {
        try tokenizer.scanValue()
        return tokenizer.currentOffset == count
    } catch {
        return false
    }
}
