// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
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
case let .run(config):
    let exitCode = await runCatalog(config)
    Foundation.exit(exitCode)
}

@MainActor
func runCatalog(_ config: InspectorConfiguration) async -> Int32 {
    var connectionConfig = config.connection
    if config.passwordFromStdin {
        guard let password = InspectorPasswordReader.readLineFromStdin() else {
            FileHandle.standardError.write(Data("error: no password received on stdin\n".utf8))
            return 64
        }
        connectionConfig = InspectorConnectionConfiguration(
            host: connectionConfig.host,
            port: connectionConfig.port,
            namespace: connectionConfig.namespace,
            usesTLS: connectionConfig.usesTLS,
            username: connectionConfig.username,
            password: password,
            connectTimeout: connectionConfig.connectTimeout
        )
    }

    let session: InspectorSession
    do {
        session = try AxolotyInspectorSession(configuration: connectionConfig)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 70
    }

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]

    let signalHandler = InspectorSignalHandler()
    signalHandler.install()

    let app = InspectorApplication(
        configuration: config,
        session: session,
        writeOutput: { line in
            print(line)
        },
        writeDiagnostic: { line in
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        },
        timestamp: {
            dateFormatter.string(from: Date())
        },
        isTerminal: InspectorTerminal.isStdoutTerminal,
        signalHandler: signalHandler
    )

    let result = await app.run()

    if let error = result {
        if error == .interrupted {
            return 130
        }
        FileHandle.standardError.write(Data("error: \(error.userFriendlyMessage)\n".utf8))
        return error.exitCode
    }

    return 0
}
