// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

struct ProbeDestination: JSONTokenizerDestination {
    typealias ArrayStartContext = Int
    typealias ObjectStartContext = Int

    var tokenCount = 0

    mutating func arrayStartFound(_ start: JSONToken.ArrayStart) -> Int {
        tokenCount += 1
        return tokenCount
    }

    mutating func arrayEndFound(_ end: JSONToken.ArrayEnd, context: consuming Int) {
        tokenCount += 1
    }

    mutating func objectStartFound(_ start: JSONToken.ObjectStart) -> Int {
        tokenCount += 1
        return tokenCount
    }

    mutating func objectEndFound(_ end: JSONToken.ObjectEnd, context: consuming Int) {
        tokenCount += 1
    }

    mutating func booleanTrueFound(_ boolean: JSONToken.BooleanTrue) { tokenCount += 1 }
    mutating func booleanFalseFound(_ boolean: JSONToken.BooleanFalse) { tokenCount += 1 }
    mutating func nullFound(_ null: JSONToken.Null) { tokenCount += 1 }
    mutating func stringFound(_ string: JSONToken.String) { tokenCount += 1 }
    mutating func numberFound(_ number: JSONToken.Number) { tokenCount += 1 }
}

func tokenizeJSON(_ bytes: UnsafePointer<UInt8>, length: Int) -> Bool {
    let buffer = UnsafeBufferPointer(start: bytes, count: length)
    var tokenizer = JSONTokenizer(bytes: buffer, destination: ProbeDestination())
    do {
        try tokenizer.scanValue()
        return tokenizer.currentOffset == length
    } catch {
        return false
    }
}
