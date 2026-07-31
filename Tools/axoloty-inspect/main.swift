// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyInspectorCore
import Foundation

let environment = InspectorEnvironmentValues(environment: ProcessInfo.processInfo.environment)
let outcome = InspectorArgumentParser().parse(
    Array(CommandLine.arguments.dropFirst()),
    environment: environment
)

switch outcome {
case .help:
    print(InspectorArgumentParser.helpText)
    Foundation.exit(0)
case .version:
    print("axoloty-inspect \(InspectorArgumentParser.version)")
    Foundation.exit(0)
case let .error(error):
    FileHandle.standardError.write(Data("error: \(error.userFriendlyMessage)\n".utf8))
    Foundation.exit(error.exitCode)
case .run:
    FileHandle.standardError.write(Data("error: catalog command is not yet implemented\n".utf8))
    Foundation.exit(70)
}
