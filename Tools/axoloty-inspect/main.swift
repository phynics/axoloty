// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
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
    let exitCode = await runInspector(config)
    Foundation.exit(exitCode)
}

@MainActor
func runInspector(
    _ config: InspectorConfiguration,
    sessionFactory: @MainActor (InspectorConnectionConfiguration) throws -> InspectorSession = { configuration in
        try AxolotyInspectorSession(configuration: configuration)
    },
    signalHandler: InspectorSignalHandling = InspectorSignalHandler()
) async -> Int32 {
    guard let logLevel = InspectorLogLevel(rawValue: config.logLevel) else {
        let error = InspectorError.invalidConfiguration(
            field: "log-level",
            reason: "must be one of: \(InspectorLogLevel.supportedValuesDescription)"
        )
        FileHandle.standardError.write(Data("error: \(error.userFriendlyMessage)\n".utf8))
        return error.exitCode
    }
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
        session = try sessionFactory(connectionConfig)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 70
    }
    applyInspectorLogLevel(logLevel)

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]

    signalHandler.install()

    let updatedConfig = InspectorConfiguration(
        command: config.command,
        connection: connectionConfig,
        output: config.output,
        logLevel: config.logLevel,
        passwordFromStdin: false
    )

    let result: InspectorError?
    switch config.command {
    case .catalog:
        let app = InspectorApplication(
            configuration: updatedConfig,
            session: session,
            writeOutput: { line in print(line) },
            writeDiagnostic: { line in
                FileHandle.standardError.write(Data("\(line)\n".utf8))
            },
            timestamp: { dateFormatter.string(from: Date()) },
            isTerminal: InspectorTerminal.isStdoutTerminal,
            signalHandler: signalHandler
        )
        result = await app.run()
    case .discover:
        let app = InspectorDiscoverApplication(
            configuration: updatedConfig,
            session: session,
            writeOutput: { line in print(line) },
            writeDiagnostic: { line in
                FileHandle.standardError.write(Data("\(line)\n".utf8))
            },
            timestamp: { dateFormatter.string(from: Date()) },
            isTerminal: InspectorTerminal.isStdoutTerminal,
            signalHandler: signalHandler
        )
        result = await app.run()
    }

    if let error = result {
        if error == .interrupted {
            return 130
        }
        FileHandle.standardError.write(Data("error: \(error.userFriendlyMessage)\n".utf8))
        return error.exitCode
    }

    return 0
}

/// Applies the validated inspector level before inspector lifecycle work begins.
func applyInspectorLogLevel(_ level: InspectorLogLevel) {
    switch level {
    case .trace:
        LogManager.setLevel(.trace, for: nil)
    case .debug:
        LogManager.setLevel(.debug, for: nil)
    case .info:
        LogManager.setLevel(.info, for: nil)
    case .notice:
        LogManager.setLevel(.notice, for: nil)
    case .warning:
        LogManager.setLevel(.warning, for: nil)
    case .error:
        LogManager.setLevel(.error, for: nil)
    }
}
