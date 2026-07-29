// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Foundation

let result = AxolotyCommandDispatcher().run(arguments: Array(CommandLine.arguments.dropFirst()))

if !result.standardOutput.isEmpty {
    print(result.standardOutput)
}

if !result.standardError.isEmpty {
    FileHandle.standardError.write(Data(result.standardError.utf8))
}

Foundation.exit(result.exitCode)
