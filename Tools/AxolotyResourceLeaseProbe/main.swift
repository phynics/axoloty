// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation

var resource: String?
var readyPath: String?
var timeoutSeconds: TimeInterval = 0
var hold = false
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--resource":
        index += 1
        guard index < CommandLine.arguments.count else { Foundation.exit(64) }
        resource = CommandLine.arguments[index]
    case "--ready":
        index += 1
        guard index < CommandLine.arguments.count else { Foundation.exit(64) }
        readyPath = CommandLine.arguments[index]
    case "--timeout":
        index += 1
        guard index < CommandLine.arguments.count, let value = TimeInterval(CommandLine.arguments[index]) else {
            Foundation.exit(64)
        }
        timeoutSeconds = value
    case "--hold":
        hold = true
    default:
        Foundation.exit(64)
    }
    index += 1
}

guard let resource else { Foundation.exit(64) }
let owner = "resource-probe"
let lease: any AxolotyResourceLease
do {
    lease = try FoundationResourceLeaseManager().acquire(
        resource: resource,
        timeoutSeconds: timeoutSeconds,
        owner: owner
    )
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("\(error.localizedDescription)\n".utf8))
    Foundation.exit(75)
}

if let readyPath {
    _ = FileManager.default.createFile(atPath: readyPath, contents: Data())
}

if hold {
    withExtendedLifetime(lease) {
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

withExtendedLifetime(lease) {}

