// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

let valid = Array(#"{"payload":[1,true,null,"text"]}"#.utf8)
let invalid = Array(#"{"payload":[1,true}"#.utf8)
let malformed = [
    #"{"payload":tru}"#,
    #"{"payload":[1,2}"#,
    #"{"payload":1}trailing"#,
    #"{"payload":"\uD800"}"#,
    #"{"payload":01}"#,
]

precondition(valid.withUnsafeBufferPointer {
    tokenizeJSON($0.baseAddress!, length: $0.count)
})
precondition(!invalid.withUnsafeBufferPointer {
    tokenizeJSON($0.baseAddress!, length: $0.count)
})

let malformedAccepted = malformed.reduce(into: 0) { count, input in
    let bytes = Array(input.utf8)
    if bytes.withUnsafeBufferPointer({
        tokenizeJSON($0.baseAddress!, length: $0.count)
    }) {
        count += 1
    }
}
for (index, input) in malformed.enumerated() {
    let bytes = Array(input.utf8)
    let accepted = bytes.withUnsafeBufferPointer {
        tokenizeJSON($0.baseAddress!, length: $0.count)
    }
    precondition(accepted == (index >= 3))
}

print("IKIGA JSON CORE HOST OK")
print("malformedAccepted=\(malformedAccepted)/\(malformed.count)")
