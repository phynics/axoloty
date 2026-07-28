// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

private let version = "0.1.0"

private let usage = """
Usage: ax <command>

Axoloty's typed build and test orchestration CLI.

Commands:
  help, --help, -h     Show this help.
  version, --version   Show the CLI version.

The initial command surface is intentionally small. Workflow commands are
introduced only when their execution contracts and structured results exist.
"""

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

switch Array(CommandLine.arguments.dropFirst()) {
case [], ["help"], ["--help"], ["-h"]:
    print(usage)
case ["version"], ["--version"]:
    print("ax \(version)")
default:
    writeStandardError("error: unsupported ax command\n\n\(usage)\n")
    Foundation.exit(64)
}
