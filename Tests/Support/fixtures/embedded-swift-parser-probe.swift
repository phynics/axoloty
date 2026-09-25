// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
struct EmbeddedSwiftParserProbe {
    static func classification(_ bytes: [UInt8]) -> UInt8 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 255 }
            let reader = WireReader(bytes: base, length: buffer.count)
            guard let failure = reader.index.failure else { return 0 }
            switch failure.reason {
            case .unexpectedEndOfInput: return 1
            case .invalidLiteral: return 2
            case .invalidNumber: return 3
            case .invalidNesting: return 4
            default: return 255
            }
        }
    }

    static func main() {
        precondition(classification([123, 125]) == 0)
        precondition(classification([123, 34, 120, 34, 58]) == 1)
        precondition(classification([123, 34, 120, 34, 58, 116, 114, 117, 116, 104, 125]) == 2)
        precondition(classification([123, 34, 120, 34, 58, 48, 49, 125]) == 3)
        precondition(classification([123, 34, 120, 34, 58, 91, 123, 93, 125, 125]) == 4)
    }
}
