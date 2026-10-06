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

/// A host with pinned, checksum-verified Zenoh release archives.
///
/// Each case's raw value is the Rust target triple that names its archives.
enum AxolotyZenohHost: String, CaseIterable, Sendable {
    /// Linux on x86_64, the pinned project container.
    case linuxX86_64 = "x86_64-unknown-linux-gnu"
    /// macOS on Apple silicon, with the native Swift toolchain.
    case macOSARM64 = "aarch64-apple-darwin"

    /// The host this tool was built for, or `nil` when no archives are pinned
    /// for it.
    static let current: AxolotyZenohHost? = {
        #if os(Linux) && arch(x86_64)
        .linuxX86_64
        #elseif os(macOS) && arch(arm64)
        .macOSARM64
        #else
        nil
        #endif
    }()

    /// The hosts a Zenoh tier can run on, for diagnostics.
    static let supportedDescription = "Linux x86_64 or macOS arm64"

    /// The pinned `zenohd` router archive name.
    var routerArchive: String { "zenoh-\(AxolotyZenohToolchain.version)-\(rawValue)-standalone.zip" }

    /// The pinned `zenoh-c` archive name.
    var cArchive: String { "zenoh-c-\(AxolotyZenohToolchain.version)-\(rawValue)-standalone.zip" }

    /// The SHA-256 of `routerArchive`.
    var routerChecksum: String {
        switch self {
        case .linuxX86_64: "43de097382e3db4f95903cbadbbf472a21fbea53d6a3193606ae12b034a20881"
        case .macOSARM64: "00432b7efe7e84a230bad98b0995b5c2ab3757e8501c126f3b2d239fc0931610"
        }
    }

    /// The SHA-256 of `cArchive`.
    var cChecksum: String {
        switch self {
        case .linuxX86_64: "1168b3dffa7f4f48ffabfd640a3878ec0527c0a612ce825aa6f93e2cd05762d1"
        case .macOSARM64: "0f5aed4e9e618b13d37518c8c19fb03210050843ca0cf7b6105f367a6c32a97c"
        }
    }

    /// Whether the host is a Darwin platform.
    var isDarwin: Bool { self == .macOSARM64 }
}

/// An unpacked, checksum-verified zenoh-c archive whose `zenohc.pc` names its
/// own location.
struct AxolotyZenohCInstallation: Sendable {
    /// The host the archive was pinned for.
    let host: AxolotyZenohHost
    /// The directory containing the rewritten `zenohc.pc`.
    let pkgConfigDirectory: URL
    /// The directory containing the zenoh-c headers.
    let includeDirectory: URL
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

    /// Extra `swift build` or `swift test` arguments that let linked products
    /// load the shared library.
    ///
    /// SwiftPM keeps only `-L` and `-l` from pkg-config output, and macOS
    /// strips `DYLD_LIBRARY_PATH` from the SIP-protected launchers, so Darwin
    /// products need an explicit runtime search path. Linux uses
    /// `LD_LIBRARY_PATH` from ``environment(extending:)``.
    var swiftLinkerArguments: [String] {
        host.isDarwin ? ["-Xlinker", "-rpath", "-Xlinker", libraryDirectory.path] : []
    }

    /// C compiler and linker arguments for a standalone C client.
    var cCompilerArguments: [String] {
        ["-I\(includeDirectory.path)", "-L\(libraryDirectory.path)", "-lzenohc"]
            + (host.isDarwin ? ["-Wl,-rpath,\(libraryDirectory.path)"] : [])
    }
}

/// Provisions the pinned Zenoh 1.10.0 release archives and runs the host
/// commands that the Zenoh tiers share.
struct AxolotyZenohToolchain {
    static let version = "1.10.0"
    private static let routerRelease = "https://github.com/eclipse-zenoh/zenoh/releases/download/1.10.0"
    private static let cRelease = "https://github.com/eclipse-zenoh/zenoh-c/releases/download/1.10.0"

    let environment: [String: String]
    /// The host whose pinned archives this toolchain provisions, or `nil` on
    /// an unsupported host.
    let host: AxolotyZenohHost?

    init(environment: [String: String], host: AxolotyZenohHost? = .current) {
        self.environment = environment
        self.host = host
    }

    /// Returns the supported host or fails before any download.
    ///
    /// - Parameter tier: The tier name reported in the failure.
    /// - Returns: The host with pinned archives.
    /// - Throws: `AxolotyZenohCommandError.invalidOutput` on an unsupported host.
    @discardableResult
    func requireSupportedHost(for tier: String) throws(AxolotyZenohCommandError) -> AxolotyZenohHost {
        guard let host else {
            throw .invalidOutput("the pinned \(tier) tier requires \(AxolotyZenohHost.supportedDescription)")
        }
        return host
    }

    /// Provisions the pinned zenoh-c archive under `directory` and rewrites its
    /// hardcoded pkg-config prefix.
    ///
    /// - Parameter directory: The cache directory that owns the archive.
    /// - Returns: The usable installation.
    /// - Throws: `AxolotyZenohCommandError` when download, verification, or
    ///   unpacking fails.
    func provisionZenohC(in directory: URL) throws(AxolotyZenohCommandError) -> AxolotyZenohCInstallation {
        let host = try requireSupportedHost(for: "Zenoh")
        try createDirectory(directory)
        try provision(host.cArchive, checksum: host.cChecksum, release: Self.cRelease, in: directory)
        let pkgConfig = try requireFile(named: "zenohc.pc", under: directory.appending(path: "unpacked"))
        let pkgConfigDirectory = pkgConfig.deletingLastPathComponent()
        let root = pkgConfigDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try rewritePkgConfig(at: pkgConfig, prefix: root.path)
        let installation = AxolotyZenohCInstallation(
            host: host,
            pkgConfigDirectory: pkgConfigDirectory,
            includeDirectory: root.appending(path: "include"),
            libraryDirectory: root.appending(path: "lib")
        )
        if host.isDarwin {
            try relocateDarwinLibrary(in: installation.libraryDirectory)
        }
        return installation
    }

    /// Gives the Darwin shared library an rpath-relative install name.
    ///
    /// The upstream `1.10.0` archive records its CI build path as the install
    /// name, so products linked against it cannot load it. Rewriting the name
    /// invalidates the signature; an ad-hoc signature restores a loadable
    /// library on Apple silicon.
    private func relocateDarwinLibrary(in libraryDirectory: URL) throws(AxolotyZenohCommandError) {
        let library = libraryDirectory.appending(path: "libzenohc.dylib").path
        try runCommand("install_name_tool", arguments: ["-id", "@rpath/libzenohc.dylib", library])
        try runCommand("codesign", arguments: ["--force", "--sign", "-", library])
    }

    /// Provisions the pinned zenohd router archive under `directory`.
    ///
    /// - Parameter directory: The cache directory that owns the archive.
    /// - Returns: The executable router binary.
    /// - Throws: `AxolotyZenohCommandError` when download, verification, or
    ///   unpacking fails, or the binary cannot be made executable.
    func provisionRouter(in directory: URL) throws(AxolotyZenohCommandError) -> URL {
        let host = try requireSupportedHost(for: "Zenoh")
        try createDirectory(directory)
        try provision(host.routerArchive, checksum: host.routerChecksum, release: Self.routerRelease, in: directory)
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
            if digest(of: archiveURL) != checksum {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }
        if !FileManager.default.fileExists(atPath: archiveURL.path) {
            try runCommand("curl", arguments: ["--fail", "--location", "--retry", "3", "--output", archiveURL.path, "\(release)/\(archive)"])
        }
        guard digest(of: archiveURL) == checksum else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw .invalidArchive("SHA-256 mismatch for pinned archive \(archive)")
        }
        // A worktree shared between the Linux container and native macOS keeps
        // one cache directory, so the marker names the archive it came from.
        let unpacked = directory.appending(path: "unpacked")
        let marker = unpacked.appending(path: ".axoloty-archive")
        let expectedMarker = "\(archive) \(checksum)\n"
        if (try? String(contentsOf: marker, encoding: .utf8)) != expectedMarker {
            try? FileManager.default.removeItem(at: unpacked)
            try runCommand("unzip", arguments: ["-q", "-o", archiveURL.path, "-d", unpacked.path])
            do {
                try expectedMarker.write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                throw .invalidArchive("cannot record unpacked archive \(archive): \(error.localizedDescription)")
            }
        }
    }

    /// Returns the lowercase SHA-256 of `file`, or `nil` when it cannot be read.
    private func digest(of file: URL) -> String? {
        let command = host?.isDarwin == true ? ("shasum", ["-a", "256", file.path]) : ("sha256sum", [file.path])
        let output = (try? runCommand(command.0, arguments: command.1)) ?? ""
        return output.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
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
