// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

let bytes = Array(#"{"value":[1,true,null]}"#.utf8)
precondition(bytes.withUnsafeBufferPointer {
    validJSON($0.baseAddress!, count: $0.count)
})
print("IKIGA JSON CORE PRODUCT CONSUMER OK")
