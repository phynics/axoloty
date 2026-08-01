// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

let associate = Array(#"{"ioActorId":"00000000-0000-4000-8000-000000000002","unknown":{"nested":[true,null,1.25e2]},"associatingRoute":"line\nroute","updateRate":25,"ioSourceId":"00000000-0000-4000-8000-000000000001","isExternalRoute":true}"#.utf8)
let ioValue = Array(#"{"payload":{"values":[1,"two",null],"valid":true}}"#.utf8)
let malformed = [
    #"{"payload":tru}"#,
    #"{"payload":[1,2}"#,
    #"{"payload":1}trailing"#,
    #"{"payload":"\uD800"}"#,
    #"{"payload":01}"#,
]

associate.withUnsafeBufferPointer { buffer in
    var reader = NativeStrictReader(bytes: buffer.baseAddress!, length: buffer.count)
    let decoded = try! reader.decodeAssociate()
    precondition(decoded.updateRate == 25)
    precondition(decoded.isExternalRoute == true)
    precondition(decoded.associatingRoute?.equals("line\\nroute") == true)
}

ioValue.withUnsafeBufferPointer { buffer in
    var reader = NativeStrictReader(bytes: buffer.baseAddress!, length: buffer.count)
    let decoded = try! reader.decodeIoValue()
    precondition(decoded.payload.equals(#"{"values":[1,"two",null],"valid":true}"#))
}

var existingMalformedAccepted = 0
for input in malformed {
    let bytes = Array(input.utf8)
    let accepted = bytes.withUnsafeBufferPointer { buffer in
        var reader = NativeStrictReader(bytes: buffer.baseAddress!, length: buffer.count)
        return (try? reader.decodeIoValue()) != nil
    }
    precondition(!accepted, "strict reader accepted malformed input")
    let existingAccepted = bytes.withUnsafeBufferPointer { buffer in
        let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
        return (try? IoValueWireData(from: reader)) != nil
    }
    if existingAccepted { existingMalformedAccepted += 1 }
}

let unescaped = Array("quote=\" newline=\n tab=\t".utf8)
var output = Array(repeating: UInt8(0), count: 128)
let encodedCount = unescaped.withUnsafeBufferPointer { input in
    output.withUnsafeMutableBufferPointer { destination in
        let slice = ByteSlice(bytes: input.baseAddress!, length: input.count)
        var writer = NativeEscapingWriter(buffer: destination.baseAddress!, capacity: destination.count)
        try! writer.writeJSONString(slice)
        return writer.position
    }
}
let encoded = String(decoding: output.prefix(encodedCount), as: UTF8.self)
precondition(encoded == #""quote=\" newline=\n tab=\t""#)

func nanoseconds(iterations: Int, _ operation: () -> Int) -> Int {
    let clock = ContinuousClock()
    var checksum = 0
    let elapsed = clock.measure {
        for _ in 0..<iterations { checksum &+= operation() }
    }
    precondition(checksum != 0)
    let total = Int(elapsed.components.seconds) * 1_000_000_000
        + Int(elapsed.components.attoseconds / 1_000_000_000)
    return total / iterations
}

let sampleCount = 21
let iterations = 50_000
let nativeSamples = associate.withUnsafeBufferPointer { buffer in
    (0..<sampleCount).map { _ in
        nanoseconds(iterations: iterations) {
            var reader = NativeStrictReader(bytes: buffer.baseAddress!, length: buffer.count)
            return (try? reader.decodeAssociate())?.updateRate ?? 0
        }
    }
}
let existingSamples = associate.withUnsafeBufferPointer { buffer in
    (0..<sampleCount).map { _ in
        nanoseconds(iterations: iterations) {
            let reader = WireReader(bytes: buffer.baseAddress!, length: buffer.count)
            return (try? AssociateWireData(from: reader))?.updateRate ?? 0
        }
    }
}

func percentile(_ samples: [Int], _ percentage: Int) -> Int {
    let ordered = samples.sorted()
    return ordered[min(ordered.count - 1, ordered.count * percentage / 100)]
}

print("NATIVE STRICT SPIKE OK")
print("associateSamples=\(sampleCount)x\(iterations)")
print("strictP50Ns=\(percentile(nativeSamples, 50))")
print("strictP95Ns=\(percentile(nativeSamples, 95))")
print("existingP50Ns=\(percentile(existingSamples, 50))")
print("existingP95Ns=\(percentile(existingSamples, 95))")
print("strictMalformedAccepted=0")
print("existingMalformedAccepted=\(existingMalformedAccepted)/\(malformed.count)")
print("escapedOutput=\(encoded)")
