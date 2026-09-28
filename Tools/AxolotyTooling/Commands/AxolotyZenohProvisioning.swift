// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum AxolotyZenohCommandError: Error, LocalizedError, Sendable {
    case commandFailed(String, Int32, String)
    case invalidOutput(String)
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, output):
            "\(command) exited with status \(status): \(output)"
        case let .invalidOutput(message), let .invalidArchive(message): message
        }
    }
}

/// An unpacked, checksum-verified zenoh-c archive whose `zenohc.pc` names its
/// own location.
struct AxolotyZenohCInstallation: Sendable {
    /// The directory containing the rewritten `zenohc.pc`.
    let pkgConfigDirectory: URL
    /// The directory containing the zenoh-c shared library.
    let libraryDirectory: URL

    /// Returns `environment` with pkg-config and the runtime loader pointed at
    /// this installation ahead of any inherited search path.
    ///
    /// - Parameter environment: The environment to extend.
    /// - Returns: The extended environment.
    func environment(extending environment: [String: String]) -> [String: String] {
        var result = environment
        result["PKG_CONFIG_PATH"] = [pkgConfigDirectory.path, environment["PKG_CONFIG_PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        result["LD_LIBRARY_PATH"] = [libraryDirectory.path, environment["LD_LIBRARY_PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        return result
    }
}

/// Provisions the pinned Zenoh 1.10.0 release archives and runs the host
/// commands that the Zenoh tiers share.
struct AxolotyZenohToolchain {
    static let version = "1.10.0"
    private static let routerArchive = "zenoh-1.10.0-x86_64-unknown-linux-gnu-standalone.zip"
    private static let routerChecksum = "43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881"
    private static let routerRelease = "https://github.com/eclipse-zenoh/zenoh/releases/download/1.10.0"
    private static let cArchive = "zenoh-c-1.10.0-x86_64-unknown-linux-gnu-standalone.zip"
    private static let cChecksum = "1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1"
    private static let cRelease = "https://github.com/eclipse-zenoh/zenoh-c/releases/download/1.10.0"

    let environment: [String: String]

    /// Provisions the pinned zenoh-c archive under `directory` and rewrites its
    /// hardcoded pkg-config prefix.
    ///
    /// - Parameter directory: The cache directory that owns the archive.
    /// - Returns: The usable installation.
    /// - Throws: `AxolotyZenohCommandError` when download, verification, or
    ///   unpacking fails.
    func provisionZenohC(in directory: URL) throws(AxolotyZenohCommandError) -> AxolotyZenohCInstallation {
        try createDirectory(directory)
        try provision(Self.cArchive, checksum: Self.cChecksum, release: Self.cRelease, in: directory)
        let pkgConfig = try requireFile(named: "zenohc.pc", under: directory.appending(path: "unpacked"))
        let pkgConfigDirectory = pkgConfig.deletingLastPathComponent()
        let root = pkgConfigDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try rewritePkgConfig(at: pkgConfig, prefix: root.path)
        return AxolotyZenohCInstallation(
            pkgConfigDirectory: pkgConfigDirectory,
            libraryDirectory: root.appending(path: "lib")
        )
    }

    /// Provisions the pinned zenohd router archive under `directory`.
    ///
    /// - Parameter directory: The cache directory that owns the archive.
    /// - Returns: The executable router binary.
    /// - Throws: `AxolotyZenohCommandError` when download, verification, or
    ///   unpacking fails, or the binary cannot be made executable.
    func provisionRouter(in directory: URL) throws(AxolotyZenohCommandError) -> URL {
        try createDirectory(directory)
        try provision(Self.routerArchive, checksum: Self.routerChecksum, release: Self.routerRelease, in: directory)
        let routerBinary = try requireFile(named: "zenohd", under: directory.appending(path: "unpacked"))
        try runCommand("chmod", arguments: ["u+x", routerBinary.path])
        guard FileManager.default.isExecutableFile(atPath: routerBinary.path) else {
            throw .invalidArchive("zenohd from the pinned archive could not be made executable")
        }
        return routerBinary
    }

    func createDirectory(_ directory: URL) throws(AxolotyZenohCommandError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .invalidOutput("cannot create Zenoh scratch directory: \(error.localizedDescription)")
        }
    }

    private func provision(
        _ archive: String,
        checksum: String,
        release: String,
        in directory: URL
    ) throws(AxolotyZenohCommandError) {
        let archiveURL = directory.appending(path: archive)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let priorDigest = (try? runCommand("sha256sum", arguments: [archiveURL.path])) ?? ""
            if priorDigest.split(whereSeparator: \.isWhitespace).first.map(String.init) != checksum {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }
        if !FileManager.default.fileExists(atPath: archiveURL.path) {
            try runCommand("curl", arguments: ["--fail", "--location", "--retry", "3", "--output", archiveURL.path, "\(release)/\(archive)"])
        }
        let verified = (try? runCommand("sha256sum", arguments: [archiveURL.path])) ?? ""
        guard verified.split(whereSeparator: \.isWhitespace).first.map(String.init) == checksum else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw .invalidArchive("SHA-256 mismatch for pinned archive \(archive)")
        }
        let unpacked = directory.appending(path: "unpacked")
        if !FileManager.default.fileExists(atPath: unpacked.path) {
            try runCommand("unzip", arguments: ["-q", "-o", archiveURL.path, "-d", unpacked.path])
        }
    }

    private func requireFile(named name: String, under directory: URL) throws(AxolotyZenohCommandError) -> URL {
        let output = try runCommand("find", arguments: [directory.path, "-type", "f", "-name", name, "-print", "-quit"])
        guard let first = output.split(whereSeparator: \.isNewline).first else {
            throw .invalidArchive("pinned archive is missing \(name)")
        }
        return URL(fileURLWithPath: String(first))
    }

    private func rewritePkgConfig(at file: URL, prefix: String) throws(AxolotyZenohCommandError) {
        do {
            let original = try String(contentsOf: file, encoding: .utf8)
            let updated = original.replacingOccurrences(of: "prefix=/usr/local", with: "prefix=\(prefix)")
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw .invalidArchive("cannot rewrite zenohc.pc: \(error.localizedDescription)")
        }
    }

    /// Runs `executable` through `/usr/bin/env` and fails on a nonzero status.
    ///
    /// - Parameters:
    ///   - executable: The command name to resolve on `PATH`.
    ///   - arguments: The command arguments.
    ///   - childEnvironment: The child environment; the toolchain environment
    ///     when `nil`.
    ///   - streamsOutput: Whether the child writes directly to this process's
    ///     standard error instead of a captured pipe.
    /// - Returns: The captured combined output, or an empty string when
    ///   streaming.
    /// - Throws: `AxolotyZenohCommandError` when the command cannot start or
    ///   exits unsuccessfully.
    @discardableResult
    func runCommand(
        _ executable: String,
        arguments: [String],
        environment childEnvironment: [String: String]? = nil,
        streamsOutput: Bool = false
    ) throws(AxolotyZenohCommandError) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = childEnvironment ?? environment
        let output: Pipe?
        if streamsOutput {
            output = nil
            // Child diagnostics stay off machine-readable stdout.
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
        } else {
            let pipe = Pipe()
            output = pipe
            process.standardOutput = pipe
            process.standardError = pipe
        }
        do {
            try process.run()
        } catch {
            throw .invalidOutput("cannot run \(executable): \(error.localizedDescription)")
        }
        let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw .commandFailed(([executable] + arguments).joined(separator: " "), process.terminationStatus, text)
        }
        return text
    }
}
