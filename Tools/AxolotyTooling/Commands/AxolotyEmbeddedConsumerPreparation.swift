// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The stable preparation manifest consumed by an external Embedded Swift
/// firmware checkout.
struct AxolotyEmbeddedConsumerPreparationReport: Codable, Equatable, Sendable {
    struct Core: Codable, Equatable, Sendable {
        let sourceDir: String
        let sha: String
        let dirty: Bool
    }

    struct Swift: Codable, Equatable, Sendable {
        let toolsVersion: String
        let languageMode: Int
        let compilerFlags: [String]
    }

    struct PortablePackage: Codable, Equatable, Sendable {
        let name: String
        let sourcePath: String
    }

    struct JSONCore: Codable, Equatable, Sendable {
        let revision: String
        let sourceDir: String
    }

    struct StaticRuntimeMacro: Codable, Equatable, Sendable {
        let executable: String
        let pluginModule: String
        let scratchDir: String
    }

    let schemaVersion: Int
    let status: String
    let contractSHA256: String
    let core: Core
    let swift: Swift
    let portablePackages: [PortablePackage]
    let jsonCore: JSONCore
    let staticRuntimeMacro: StaticRuntimeMacro
}

/// Implements `embedded consumer prepare` without knowing about firmware,
/// ESP-IDF, devices, or the repository's test-support scripts.
struct AxolotyEmbeddedConsumerPreparation: Sendable {
    private let environment: [String: String]
    private let commandRunner: any AxolotyCheckCommandRunning

    init(environment: [String: String], commandRunner: any AxolotyCheckCommandRunning) {
        self.environment = environment
        self.commandRunner = commandRunner
    }

    func run(arguments: [String]) -> AxolotyCommandResult {
        if arguments == ["--help"] || arguments == ["-h"] {
            return AxolotyCommandResult(
                standardOutput: "Usage: axoloty-tool embedded consumer prepare --scratch <absolute-path> --output <absolute-path>\n"
            )
        }
        guard let paths = parse(arguments) else {
            return AxolotyCommandResult(
                standardError: "error: usage: axoloty-tool embedded consumer prepare --scratch <absolute-path> --output <absolute-path>\n",
                exitCode: 64
            )
        }
        guard let source = environment["AXOLOTY_SOURCE_DIR"], !source.isEmpty,
              let coreURL = canonicalExistingDirectory(source) else {
            return failure("AXOLOTY_SOURCE_DIR must be an existing canonical Git checkout", code: 64)
        }
        guard let scratchURL = canonicalPotentialPath(paths.scratch),
              let outputURL = canonicalPotentialPath(paths.output),
              paths.scratch.hasPrefix("/"), paths.output.hasPrefix("/") else {
            return failure("scratch and output paths must be absolute", code: 64)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return failure("output must name a report file, not a directory", code: 64)
            }
        }
        guard isOutside(path: scratchURL, root: coreURL), isOutside(path: outputURL, root: coreURL) else {
            return failure("scratch and output paths must be outside AXOLOTY_SOURCE_DIR", code: 64)
        }
        guard let outputParent = existingParent(of: outputURL),
              let scratchParent = existingParent(of: scratchURL),
              isOutside(path: outputParent, root: coreURL),
              isOutside(path: scratchParent, root: coreURL) else {
            return failure("scratch and output parent directories must exist and remain outside AXOLOTY_SOURCE_DIR", code: 64)
        }
        guard executableAvailable("git") && executableAvailable("swift") else {
            return failure("swift and git are required", code: 69)
        }

        let contractURL = coreURL.appendingPathComponent(AxolotyEmbeddedConsumerContractValidator.defaultContractPath)
        guard let contractData = try? Data(contentsOf: contractURL) else {
            return failure("embedded consumer contract is missing or unreadable", code: 1)
        }
        let findings = AxolotyEmbeddedConsumerContractValidator(root: coreURL).validate()
        guard findings.isEmpty else {
            let detail = findings.map { finding in
                "\(finding.rule): \(finding.message)"
            }.joined(separator: "; ")
            return failure("embedded consumer contract failed validation: \(detail)", code: 1)
        }
        guard let contract = parseContract(contractData) else {
            return failure("embedded consumer contract has an unsupported shape", code: 1)
        }

        let gitRoot = runGit(["-C", coreURL.path, "rev-parse", "--show-toplevel"])
        guard gitRoot.exitCode == 0,
              let resolvedGitRoot = canonicalExistingDirectory(gitRoot.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
              resolvedGitRoot == coreURL else {
            return failure("AXOLOTY_SOURCE_DIR must be the canonical Git checkout root", code: 64)
        }
        let shaResult = runGit(["-C", coreURL.path, "rev-parse", "--verify", "HEAD^{commit}"])
        guard shaResult.exitCode == 0 else {
            return failure("could not determine the Core commit", code: 1)
        }
        let sha = shaResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }) else {
            return failure("Core commit is not a 40-character SHA", code: 1)
        }
        let statusResult = runGit(["-C", coreURL.path, "status", "--porcelain", "--untracked-files=normal"])
        guard statusResult.exitCode == 0 else {
            return failure("could not determine Core dirty state", code: 1)
        }
        let dirty = !statusResult.standardOutput.isEmpty

        do {
            try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        } catch {
            return failure("could not create caller-owned scratch directory: \(error.localizedDescription)", code: 1)
        }
        let lockPath = scratchURL.appendingPathComponent(".axoloty-consumer.lock")
        let lockDescriptor = open(lockPath.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX) == 0 else {
            if lockDescriptor >= 0 { close(lockDescriptor) }
            return failure("could not acquire preparation scratch lock", code: 1)
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
        let packagePath = coreURL.appendingPathComponent("Packages/AxolotyStaticRuntime").path
        let build = commandRunner.run(AxolotyCommandPlan(
            executable: "swift",
            arguments: [
                "build", "--package-path", packagePath, "--scratch-path", scratchURL.path,
                "--disable-automatic-resolution", "--configuration", "debug",
                "--target", "AxolotyStaticRuntime",
            ],
            executionContext: .project,
            timeoutSeconds: 3_600
        ))
        guard build.exitCode == 0 else {
            return failure("failed to build AxolotyStaticRuntime macro: \(bounded(build.standardError + build.standardOutput))", code: 1)
        }
        let bin = commandRunner.run(AxolotyCommandPlan(
            executable: "swift",
            arguments: [
                "build", "--package-path", packagePath, "--scratch-path", scratchURL.path,
                "--disable-automatic-resolution", "--configuration", "debug", "--show-bin-path",
            ],
            executionContext: .project,
            timeoutSeconds: 600
        ))
        guard bin.exitCode == 0 else {
            return failure("could not locate the static-runtime macro output: \(bounded(bin.standardError + bin.standardOutput))", code: 1)
        }
        let binOutput = bin.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let binLines = binOutput.split(whereSeparator: { character in character == "\n" || character == "\r" })
        let binPath = binLines.last.map(String.init) ?? ""
        let macroURL = URL(fileURLWithPath: binPath).appendingPathComponent(contract.macroExecutable)
        guard let macro = canonicalExistingFile(macroURL.path), isOutside(path: macro, root: coreURL), isWithin(path: macro, root: scratchURL) else {
            return failure("static-runtime macro executable must be inside caller-owned scratch", code: 1)
        }
        let jsonURL = scratchURL.appendingPathComponent("checkouts/swift-json/Sources/_JSONCore")
        guard let jsonCore = canonicalExistingDirectory(jsonURL.path), isWithin(path: jsonCore, root: scratchURL) else {
            return failure("resolved swift-json _JSONCore source is missing under scratch", code: 1)
        }
        let jsonCheckout = scratchURL.appendingPathComponent("checkouts/swift-json")
        let jsonSHAResult = runGit(["-C", jsonCheckout.path, "rev-parse", "--verify", "HEAD^{commit}"])
        let jsonSHA = jsonSHAResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard jsonSHAResult.exitCode == 0, jsonSHA == contract.jsonRevision,
              let lockRevision = lockedRevision(coreURL: coreURL), lockRevision == contract.jsonRevision else {
            return failure("resolved swift-json revision does not match the embedded consumer contract", code: 1)
        }

        let finalSHAResult = runGit(["-C", coreURL.path, "rev-parse", "--verify", "HEAD^{commit}"])
        let finalStatusResult = runGit(["-C", coreURL.path, "status", "--porcelain", "--untracked-files=normal"])
        guard finalSHAResult.exitCode == 0, finalStatusResult.exitCode == 0,
              finalSHAResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == sha,
              (!finalStatusResult.standardOutput.isEmpty) == dirty else {
            return failure("Core checkout changed during preparation", code: 1)
        }

        let report = AxolotyEmbeddedConsumerPreparationReport(
            schemaVersion: 1,
            status: "prepared",
            contractSHA256: sha256(contractData),
            core: .init(sourceDir: coreURL.path, sha: sha, dirty: dirty),
            swift: .init(toolsVersion: contract.swiftToolsVersion, languageMode: contract.swiftLanguageMode, compilerFlags: contract.compilerFlags),
            portablePackages: contract.packages.map { .init(name: $0.name, sourcePath: coreURL.appendingPathComponent($0.sourcePath).path) },
            jsonCore: .init(revision: contract.jsonRevision, sourceDir: jsonCore.path),
            staticRuntimeMacro: .init(executable: macro.path, pluginModule: contract.pluginModule, scratchDir: scratchURL.path)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try atomicWrite(data, to: outputURL)
        } catch {
            return failure("could not atomically write preparation report: \(error.localizedDescription)", code: 70)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
        return AxolotyCommandResult(standardOutput: output)
    }

    private struct Paths { let scratch: String; let output: String }
    private struct Package { let name: String; let sourcePath: String }
    private struct Contract {
        let packages: [Package]
        let jsonRevision: String
        let swiftToolsVersion: String
        let swiftLanguageMode: Int
        let compilerFlags: [String]
        let macroExecutable: String
        let pluginModule: String
    }

    private func parse(_ arguments: [String]) -> Paths? {
        guard arguments.count == 4, arguments[0] == "--scratch", arguments[2] == "--output" else { return nil }
        guard arguments[1].hasPrefix("/"), arguments[3].hasPrefix("/") else { return nil }
        return Paths(scratch: arguments[1], output: arguments[3])
    }

    private func parseContract(_ data: Data) -> Contract? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let swift = root["swift"] as? [String: Any],
              let tools = swift["toolsVersion"] as? String,
              let language = swift["languageMode"] as? Int,
              let flags = swift["requiredCompilerFlags"] as? [String],
              let packages = root["portablePackages"] as? [[String: Any]], packages.count == 5,
              let macro = root["staticRuntimeMacro"] as? [String: Any],
              let executable = macro["executable"] as? String,
              let plugin = macro["pluginModule"] as? String,
              let json = root["jsonCore"] as? [String: Any],
              let revision = json["revision"] as? String else { return nil }
        let parsed = packages.compactMap { object -> Package? in
            guard let name = object["package"] as? String, let source = object["sourcePath"] as? String else { return nil }
            return Package(name: name, sourcePath: source)
        }
        guard parsed.count == 5,
              parsed.map(\.name) == ["AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"] else { return nil }
        return Contract(packages: parsed, jsonRevision: revision, swiftToolsVersion: tools, swiftLanguageMode: language, compilerFlags: flags, macroExecutable: executable, pluginModule: plugin)
    }

    private func runGit(_ arguments: [String]) -> AxolotyCheckCommandResult {
        commandRunner.run(AxolotyCommandPlan(executable: "git", arguments: arguments, executionContext: .project, timeoutSeconds: 30))
    }

    private func lockedRevision(coreURL: URL) -> String? {
        let path = coreURL.appendingPathComponent("Packages/AxolotyStaticRuntime/Package.resolved")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else { return nil }
        return pins.first { ($0["identity"] as? String) == "swift-json" }?["state"].flatMap { ($0 as? [String: Any])?["revision"] as? String }
    }

    private func canonicalExistingDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private func canonicalExistingFile(_ path: String) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private func canonicalPotentialPath(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }
        var ancestor = candidate
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
            if ancestor.path == "/" { break }
        }
        guard let resolved = canonicalExistingDirectory(ancestor.path) else { return nil }
        return suffix.reduce(resolved) { $0.appendingPathComponent($1) }.standardizedFileURL
    }

    private func existingParent(of url: URL) -> URL? {
        canonicalExistingDirectory(url.deletingLastPathComponent().path)
    }

    private func isWithin(path: URL, root: URL) -> Bool {
        let child = path.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return child == base || child.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func isOutside(path: URL, root: URL) -> Bool { !isWithin(path: path, root: root) }

    private func executableAvailable(_ name: String) -> Bool {
        let paths = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        return paths.contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + name) }
    }

    private func sha256(_ data: Data) -> String {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: (0..<8).reversed().map { UInt8((bitLength >> UInt64($0 * 8)) & 0xff) })
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let roundConstants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
            0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
            0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
            0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
            0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
            0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
            0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
            0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 { (value >> amount) | (value << (32 - amount)) }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let position = offset + index * 4
                words[index] = UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, h) = (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7])
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ roundConstants[index] &+ words[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
            }
            hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
            hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .withoutOverwriting)
        if rename(temporary.path, url.path) != 0 {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: temporary)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            } else {
                try? FileManager.default.removeItem(at: temporary)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }
        }
    }

    private func bounded(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 400 ? String(clean.prefix(400)) + "…" : clean
    }

    private func failure(_ message: String, code: Int32) -> AxolotyCommandResult {
        AxolotyCommandResult(standardError: "error: \(message)\n", exitCode: code)
    }
}
