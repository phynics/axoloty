// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Minimal release consumer for the Axoloty host runtime (issue #299).
//
// Exercises one stable public path so dead stripping cannot erase the product.
// The binary size of this consumer captures the modern host runtime and error
// boundary as a release-mode baseline.

import Axoloty

let error = AxolotyError.runtime(
    code: .notStarted,
    reason: "benchmark consumer anchor"
)
switch error {
case .runtime(let code, _):
    print("AXOLOTY_CONSUMER_OK: \(code.rawValue)")
default:
    print("AXOLOTY_CONSUMER_OK: unexpected")
}
