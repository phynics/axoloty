// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation

var device: String?
var readyPath: String?
var hold = false
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--device":
        index += 1
        guard index < CommandLine.arguments.count else { Foundation.exit(64) }
        device = CommandLine.arguments[index]
    case "--ready":
        index += 1
        guard index < CommandLine.arguments.count else { Foundation.exit(64) }
        readyPath = CommandLine.arguments[index]
    case "--hold":
        hold = true
    default:
        Foundation.exit(64)
    }
    index += 1
}

guard let device else { Foundation.exit(64) }
let manager = FoundationDeviceLeaseManager()
guard let lease = manager.acquire(device: device) else { Foundation.exit(75) }

if let readyPath {
    FileManager.default.createFile(atPath: readyPath, contents: Data())
}

if hold {
    withExtendedLifetime(lease) {
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

withExtendedLifetime(lease) {}
