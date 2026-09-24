// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Validates the versioned contract consumed by the standalone Embedded Swift
/// build. The validator is intentionally internal: the repository command
/// layer owns the public reporting surface, while this type owns the package
/// and lockfile facts behind that report.
internal struct AxolotyEmbeddedConsumerContractValidator {
    internal static let defaultContractPath = "docs/embedded-consumer-contract.json"

    private static let expectedRepositoryIdentity = "phynics/axoloty"
    private static let expectedRepositoryURL = "https://github.com/phynics/axoloty.git"
    private static let expectedRevisionFormat = "git-commit-sha1"
    private static let expectedSwiftToolsVersion = "6.4"
    private static let expectedSwiftLanguageMode = 6
    private static let expectedFeatures = ["Embedded", "Lifetimes"]
    private static let expectedCompilerFlags = [
        "-swift-version", "6",
        "-enable-experimental-feature", "Embedded",
        "-enable-experimental-feature", "Lifetimes",
    ]

    private static let packages: [(name: String, path: String)] = [
        ("AxolotyWire", "Packages/AxolotyWire"),
        ("AxolotyObjectModel", "Packages/AxolotyObjectModel"),
        ("AxolotyProtocol", "Packages/AxolotyProtocol"),
        ("AxolotyCoatyModels", "Packages/AxolotyCoatyModels"),
        ("AxolotyStaticRuntime", "Packages/AxolotyStaticRuntime"),
    ]

    private static let packageSourcePaths: [String: String] = [
        "AxolotyWire": "Packages/AxolotyWire/Sources/AxolotyWire",
        "AxolotyObjectModel": "Packages/AxolotyObjectModel/Sources/AxolotyObjectModel",
        "AxolotyProtocol": "Packages/AxolotyProtocol/Sources/AxolotyProtocol",
        "AxolotyCoatyModels": "Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels",
        "AxolotyStaticRuntime": "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime",
    ]

    private let root: URL
    private let contractURL: URL

    /// Creates a validator for a checkout and its repository-relative
    /// contract path.
    ///
    /// - Parameters:
    ///   - root: The Axoloty checkout to inspect.
    ///   - contractPath: A relative contract path, or an absolute URL contained
    ///     by `root` for an isolated fixture.
    internal init(root: URL, contractPath: String = defaultContractPath) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.contractURL = Self.resolve(path: contractPath, relativeTo: root)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    /// Creates a validator using an explicit contract URL. The URL must remain
    /// inside the checkout; an out-of-tree URL is reported as an unsafe path.
    internal init(root: URL, contractPath: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.contractURL = contractPath.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns all contract and checkout-consistency findings in stable order.
    internal func validate() -> [AxolotyRepositoryAuthorityFinding] {
        var findings: [AxolotyRepositoryAuthorityFinding] = []
        guard isWithinRepository(contractURL) else {
            findings.append(finding(
                "contract.path",
                path: relativePath(contractURL),
                "contract path must remain inside the checkout"
            ))
            return findings
        }
        guard let data = try? Data(contentsOf: contractURL) else {
            findings.append(finding(
                "contract.read",
                path: relativePath(contractURL),
                "embedded consumer contract is missing or unreadable"
            ))
            return findings
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            findings.append(finding(
                "contract.json",
                path: relativePath(contractURL),
                "embedded consumer contract must be a JSON object"
            ))
            return findings
        }
        guard let contract = parseContract(object, findings: &findings) else {
            return sorted(findings)
        }

        validateRepository(contract.repository, findings: &findings)
        validateSwift(contract.swift, findings: &findings)
        validateRootManifestSwift(findings: &findings)
        validatePortablePackages(contract.portablePackages, findings: &findings)
        validatePortableModulePolicy(contract.portablePackages, findings: &findings)
        validateMacro(contract.staticRuntimeMacro, findings: &findings)
        validateJSONCore(contract.jsonCore, findings: &findings)
        validateWireBoundary(findings: &findings)
        validateLocks(contract.jsonCore, findings: &findings)

        return sorted(findings)
    }

    private struct Contract {
        let repository: Repository
        let swift: SwiftContract
        let portablePackages: [[String: Any]]
        let staticRuntimeMacro: [String: Any]
        let jsonCore: JSONCore
    }

    private struct Repository {
        let identity: String
        let url: String
        let revisionFormat: String
    }

    private struct SwiftContract {
        let toolsVersion: String
        let languageMode: Int
        let requiredExperimentalFeatures: [String]
        let requiredCompilerFlags: [String]
    }

    private struct JSONCore {
        let identity: String
        let repository: String
        let version: String
        let revision: String
        let product: String
        let module: String
        let packageName: String
        let sourcePath: String
        let lockPath: String
    }

    private func parseContract(
        _ object: [String: Any],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) -> Contract? {
        let path = relativePath(contractURL)
        guard let schemaVersion = integer(object["schemaVersion"]) else {
            findings.append(finding("contract.schema", path: path, "schemaVersion must be integer 1"))
            return nil
        }
        guard schemaVersion == 1 else {
            findings.append(finding("contract.schema", path: path, "unsupported schemaVersion \(schemaVersion); expected 1"))
            return nil
        }

        guard let repositoryObject = object["repository"] as? [String: Any] else {
            findings.append(finding("contract.repository", path: path, "repository must be an object"))
            return nil
        }
        guard let swiftObject = object["swift"] as? [String: Any] else {
            findings.append(finding("contract.swift", path: path, "swift must be an object"))
            return nil
        }
        guard let portablePackages = object["portablePackages"] as? [[String: Any]] else {
            findings.append(finding("contract.portablePackages", path: path, "portablePackages must be an array of objects"))
            return nil
        }
        guard let macroObject = object["staticRuntimeMacro"] as? [String: Any] else {
            findings.append(finding("contract.staticRuntimeMacro", path: path, "staticRuntimeMacro must be an object"))
            return nil
        }
        guard let jsonCoreObject = object["jsonCore"] as? [String: Any] else {
            findings.append(finding("contract.jsonCore", path: path, "jsonCore must be an object"))
            return nil
        }

        guard let repository = parseRepository(repositoryObject, findings: &findings),
              let swift = parseSwift(swiftObject, findings: &findings),
              let jsonCore = parseJSONCore(jsonCoreObject, findings: &findings) else {
            return nil
        }
        return Contract(
            repository: repository,
            swift: swift,
            portablePackages: portablePackages,
            staticRuntimeMacro: macroObject,
            jsonCore: jsonCore
        )
    }

    private func parseRepository(
        _ object: [String: Any],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) -> Repository? {
        let identity = string(object["identity"], key: "repository.identity", findings: &findings)
        let url = string(object["url"], key: "repository.url", findings: &findings)
        let revisionFormat = string(object["revisionFormat"], key: "repository.revisionFormat", findings: &findings)
        guard let identity, let url, let revisionFormat else { return nil }
        return Repository(identity: identity, url: url, revisionFormat: revisionFormat)
    }

    private func parseSwift(
        _ object: [String: Any],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) -> SwiftContract? {
        let toolsVersion = string(object["toolsVersion"], key: "swift.toolsVersion", findings: &findings)
        let languageMode = integer(object["languageMode"], key: "swift.languageMode", findings: &findings)
        let features = stringArray(object["requiredExperimentalFeatures"], key: "swift.requiredExperimentalFeatures", findings: &findings)
        let flags = stringArray(object["requiredCompilerFlags"], key: "swift.requiredCompilerFlags", findings: &findings)
        guard let toolsVersion, let languageMode, let features, let flags else { return nil }
        return SwiftContract(
            toolsVersion: toolsVersion,
            languageMode: languageMode,
            requiredExperimentalFeatures: features,
            requiredCompilerFlags: flags
        )
    }

    private func parseJSONCore(
        _ object: [String: Any],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) -> JSONCore? {
        let identity = string(object["identity"], key: "jsonCore.identity", findings: &findings)
        let repository = string(object["repository"], key: "jsonCore.repository", findings: &findings)
        let version = string(object["version"], key: "jsonCore.version", findings: &findings)
        let revision = string(object["revision"], key: "jsonCore.revision", findings: &findings)
        let product = string(object["product"], key: "jsonCore.product", findings: &findings)
        let module = string(object["module"], key: "jsonCore.module", findings: &findings)
        let packageName = string(object["packageName"], key: "jsonCore.packageName", findings: &findings)
        let sourcePath = string(object["sourcePath"], key: "jsonCore.sourcePath", findings: &findings)
        let lockPath = string(object["lockPath"], key: "jsonCore.lockPath", findings: &findings)
        guard let identity, let repository, let version, let revision, let product,
              let module, let packageName, let sourcePath, let lockPath else { return nil }
        return JSONCore(
            identity: identity,
            repository: repository,
            version: version,
            revision: revision,
            product: product,
            module: module,
            packageName: packageName,
            sourcePath: sourcePath,
            lockPath: lockPath
        )
    }

    private func validateRepository(
        _ repository: Repository,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        if repository.identity != Self.expectedRepositoryIdentity {
            findings.append(finding("repository.identity", path: relativePath(contractURL), "repository.identity must be \(Self.expectedRepositoryIdentity)"))
        }
        if repository.url != Self.expectedRepositoryURL {
            findings.append(finding("repository.url", path: relativePath(contractURL), "repository.url must be \(Self.expectedRepositoryURL)"))
        }
        if repository.revisionFormat != Self.expectedRevisionFormat {
            findings.append(finding("repository.revisionFormat", path: relativePath(contractURL), "repository.revisionFormat must be \(Self.expectedRevisionFormat)"))
        }
    }

    private func validateSwift(
        _ swift: SwiftContract,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let path = relativePath(contractURL)
        if swift.toolsVersion != Self.expectedSwiftToolsVersion {
            findings.append(finding("swift.toolsVersion", path: path, "toolsVersion must be \(Self.expectedSwiftToolsVersion)"))
        }
        if swift.languageMode != Self.expectedSwiftLanguageMode {
            findings.append(finding("swift.languageMode", path: path, "languageMode must be 6"))
        }
        if swift.requiredExperimentalFeatures != Self.expectedFeatures {
            findings.append(finding("swift.features", path: path, "requiredExperimentalFeatures must be exactly Embedded, Lifetimes"))
        }
        if swift.requiredCompilerFlags != Self.expectedCompilerFlags {
            findings.append(finding("swift.flags", path: path, "requiredCompilerFlags must be the canonical Embedded Swift flag sequence"))
        }
    }

    private func validatePortablePackages(
        _ entries: [[String: Any]],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let path = relativePath(contractURL)
        if entries.count != Self.packages.count {
            findings.append(finding("packages.count", path: path, "portablePackages must contain exactly five entries"))
        }
        var seen = Set<String>()
        for entry in entries {
            guard let package = stringValue(entry["package"]), !package.isEmpty else {
                findings.append(finding("packages.entry", path: path, "each portable package entry needs a non-empty package"))
                continue
            }
            if !seen.insert(package).inserted {
                findings.append(finding("packages.duplicate", path: path, "portable package \(package) is declared more than once"))
            }
            guard let expected = Self.packages.first(where: { $0.name == package }) else {
                findings.append(finding("packages.name", path: path, "unsupported portable package \(package)"))
                continue
            }
            guard let packagePath = stringValue(entry["packagePath"]),
                  let product = stringValue(entry["product"]),
                  let target = stringValue(entry["target"]),
                  let module = stringValue(entry["module"]),
                  let sourcePath = stringValue(entry["sourcePath"]) else {
                findings.append(finding("packages.fields", path: path, "portable package \(package) has incomplete identity fields"))
                continue
            }
            if packagePath != expected.path {
                findings.append(finding("packages.path", path: packagePath, "\(package) packagePath must be \(expected.path)"))
            }
            if product != package || target != package || module != package {
                findings.append(finding("packages.identity", path: packagePath, "\(package) product, target, and module must all be \(package)"))
            }
            if sourcePath != Self.packageSourcePaths[package] {
                findings.append(finding("packages.sourcePath", path: packagePath, "\(package) sourcePath must be \(Self.packageSourcePaths[package] ?? "")"))
            }
            validateRelativePath(packagePath, rule: "packages.path", findings: &findings)
            validateRelativePath(sourcePath, rule: "packages.sourcePath", findings: &findings)
            validatePackageOnDisk(
                package: package,
                packagePath: packagePath,
                sourcePath: sourcePath,
                findings: &findings
            )
        }
        for expected in Self.packages where !seen.contains(expected.name) {
            findings.append(finding("packages.missing", path: expected.path, "portable package \(expected.name) is missing from the contract"))
        }
    }

    private func validatePortableModulePolicy(
        _ entries: [[String: Any]],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let policyPath = "docs/module-policy.yml"
        guard let data = try? Data(contentsOf: root.appendingPathComponent(policyPath)),
              let policy = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = policy["targets"] as? [[String: Any]] else {
            findings.append(finding(
                "packages.modulePolicy",
                path: policyPath,
                "module policy must declare the Embedded consumer packages"
            ))
            return
        }

        let targetsByName = Dictionary(
            targets.compactMap { target -> (String, [String: Any])? in
                guard let name = stringValue(target["name"]), !name.isEmpty else { return nil }
                return (name, target)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for entry in entries {
            guard let package = stringValue(entry["package"]),
                  let sourcePath = stringValue(entry["sourcePath"]) else { continue }
            guard let target = targetsByName[package] else {
                findings.append(finding(
                    "packages.modulePolicy",
                    path: policyPath,
                    "portable package \(package) is missing from module policy"
                ))
                continue
            }
            if stringValue(target["platformClass"]) != "portable" {
                findings.append(finding(
                    "packages.modulePolicy",
                    path: policyPath,
                    "portable package \(package) must use platformClass portable"
                ))
            }
            if stringValue(target["path"]) != sourcePath {
                findings.append(finding(
                    "packages.modulePolicy",
                    path: policyPath,
                    "portable package \(package) path must match its consumer contract sourcePath"
                ))
            }
        }
    }

    private func validateRootManifestSwift(
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        guard let manifest = read("Package.swift") else { return }
        if firstCapture(#"^//\s*swift-tools-version:\s*([0-9]+\.[0-9]+)"#, in: manifest, options: [.anchorsMatchLines]) != Self.expectedSwiftToolsVersion {
            findings.append(finding("root.toolsVersion", path: "Package.swift", "root Package.swift must declare Swift tools version \(Self.expectedSwiftToolsVersion)"))
        }
        if firstCapture(#"\bswiftLanguageModes\s*:\s*\[\s*\.v([0-9]+)\s*\]"#, in: manifest) != String(Self.expectedSwiftLanguageMode) {
            findings.append(finding("root.languageMode", path: "Package.swift", "root Package.swift must declare Swift language mode \(Self.expectedSwiftLanguageMode)"))
        }
    }

    private func validatePackageOnDisk(
        package: String,
        packagePath: String,
        sourcePath: String,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let packageURL = root.appendingPathComponent(packagePath).standardizedFileURL
        guard isWithinRepository(packageURL) else {
            findings.append(finding("packages.path", path: packagePath, "packagePath escapes the checkout"))
            return
        }
        let manifestPath = packagePath + "/Package.swift"
        guard let manifest = read(manifestPath) else {
            findings.append(finding("packages.manifest", path: manifestPath, "missing package manifest for \(package)"))
            return
        }
        if packageName(in: manifest) != package {
            findings.append(finding("packages.manifestIdentity", path: manifestPath, "Package.swift must declare package name \(package)"))
        }
        if firstCapture(#"^//\s*swift-tools-version:\s*([0-9]+\.[0-9]+)"#, in: manifest, options: [.anchorsMatchLines]) != Self.expectedSwiftToolsVersion {
            findings.append(finding("packages.toolsVersion", path: manifestPath, "Package.swift must declare Swift tools version \(Self.expectedSwiftToolsVersion)"))
        }
        if firstCapture(#"\bswiftLanguageModes\s*:\s*\[\s*\.v([0-9]+)\s*\]"#, in: manifest) != String(Self.expectedSwiftLanguageMode) {
            findings.append(finding("packages.languageMode", path: manifestPath, "Package.swift must declare Swift language mode \(Self.expectedSwiftLanguageMode)"))
        }
        let sourceURL = root.appendingPathComponent(sourcePath).standardizedFileURL
        guard isWithinRepository(sourceURL), sourceURL.path.hasPrefix(packageURL.path + "/"),
              sourceTreeIsContained(sourceURL) else {
            findings.append(finding("packages.sourcePath", path: packagePath, "sourcePath must remain inside its package"))
            return
        }
        guard directoryContainsSwift(sourceURL) else {
            findings.append(finding("packages.sources", path: packagePath + "/" + sourcePath, "sourcePath must contain Swift source files"))
            return
        }
        guard let target = declarationBlock(kind: "target", name: package, in: manifest)
                ?? declarationBlock(kind: "macro", name: package, in: manifest) else {
            findings.append(finding("packages.target", path: manifestPath, "Package.swift must declare target \(package)"))
            return
        }
        let packageRelativeSourcePath = sourcePath.hasPrefix(packagePath + "/")
            ? String(sourcePath.dropFirst(packagePath.count + 1))
            : sourcePath
        if firstCapture(#"\bpath\s*:\s*"([^"]+)"#, in: target) != packageRelativeSourcePath {
            findings.append(finding("packages.targetPath", path: manifestPath, "target \(package) must point to \(sourcePath)"))
        }
        guard let rootManifest = read("Package.swift") else {
            findings.append(finding("packages.rootManifest", path: "Package.swift", "root Package.swift is missing"))
            return
        }
        guard let rootTarget = declarationBlock(kind: "target", name: package, in: rootManifest) else {
            findings.append(finding("packages.rootTarget", path: "Package.swift", "root Package.swift must declare target \(package)"))
            return
        }
        if firstCapture(#"\bpath\s*:\s*"([^"]+)"#, in: rootTarget) != sourcePath {
            findings.append(finding("packages.rootTargetPath", path: "Package.swift", "root target \(package) must point to \(sourcePath)"))
        }
        if !libraryProduct(name: package, in: rootManifest) {
            findings.append(finding("packages.rootProduct", path: "Package.swift", "root Package.swift must publish library product \(package)"))
        }
    }

    private func validateMacro(
        _ entry: [String: Any],
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let path = relativePath(contractURL)
        let values = ["package", "packagePath", "buildTarget", "target", "executable", "pluginModule"]
            .reduce(into: [String: String]()) { result, key in
                if let value = stringValue(entry[key]) { result[key] = value }
                else { findings.append(finding("macro.fields", path: path, "staticRuntimeMacro is missing string field \(key)")) }
            }
        guard values.count == 6 else { return }
        let expected: [String: String] = [
            "package": "AxolotyStaticRuntime",
            "packagePath": "Packages/AxolotyStaticRuntime",
            "buildTarget": "AxolotyStaticRuntime",
            "target": "AxolotyStaticRuntimeMacrosImplementation",
            "executable": "AxolotyStaticRuntimeMacrosImplementation-tool",
            "pluginModule": "AxolotyStaticRuntimeMacrosImplementation",
        ]
        for key in expected.keys.sorted() where values[key] != expected[key] {
            findings.append(finding("macro.\(key)", path: path, "staticRuntimeMacro.\(key) must be \(expected[key] ?? "")"))
        }
        let packagePath = values["packagePath"]!
        guard let manifest = read(packagePath + "/Package.swift") else {
            findings.append(finding("macro.manifest", path: packagePath + "/Package.swift", "static-runtime package manifest is missing"))
            return
        }
        guard let macroTarget = declarationBlock(kind: "macro", name: values["target"]!, in: manifest) else {
            findings.append(finding("macro.declaration", path: packagePath + "/Package.swift", "static-runtime manifest must declare the macro target"))
            return
        }
        let requiredDependencies = [
            "SwiftCompilerPlugin", "SwiftDiagnostics", "SwiftSyntax", "SwiftSyntaxBuilder", "SwiftSyntaxMacros",
        ]
        for dependency in requiredDependencies where !macroTarget.contains("name: \"\(dependency)\"") {
            findings.append(finding("macro.dependency", path: packagePath + "/Package.swift", "macro target must depend on SwiftSyntax product \(dependency)"))
        }
        let macroSourcePath = "Sources/AxolotyStaticRuntimeMacrosImplementation"
        if firstCapture(#"\bpath\s*:\s*"([^"]+)"#, in: macroTarget) != macroSourcePath {
            findings.append(finding("macro.sourcePath", path: packagePath + "/Package.swift", "macro target must point to \(macroSourcePath)"))
        }
        let macroSourceURL = root.appendingPathComponent(packagePath + "/" + macroSourcePath).standardizedFileURL
        if !sourceTreeIsContained(macroSourceURL) || !directoryContainsSwift(macroSourceURL) {
            findings.append(finding("macro.sourcePath", path: packagePath + "/" + macroSourcePath, "macro source must be a Swift source directory inside the checkout"))
        }
        guard let runtimeTarget = declarationBlock(kind: "target", name: values["buildTarget"]!, in: manifest) else {
            findings.append(finding("macro.buildTarget", path: packagePath + "/Package.swift", "static-runtime manifest must declare build target \(values["buildTarget"]!)"))
            return
        }
        if !runtimeTarget.contains("\"\(values["target"]!)\"") {
            findings.append(finding("macro.buildDependency", path: packagePath + "/Package.swift", "build target must depend on the macro target"))
        }
        if !libraryProduct(name: "AxolotyStaticRuntime", in: manifest) {
            findings.append(finding("macro.product", path: packagePath + "/Package.swift", "static-runtime package must publish AxolotyStaticRuntime"))
        }
        validateRelativePath(packagePath, rule: "macro.path", findings: &findings)
    }

    private func validateJSONCore(
        _ jsonCore: JSONCore,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let path = relativePath(contractURL)
        if jsonCore.identity != "swift-json" {
            findings.append(finding("jsonCore.identity", path: path, "jsonCore.identity must be swift-json"))
        }
        if jsonCore.repository != "https://github.com/phynics/swift-json.git" {
            findings.append(finding("jsonCore.repository", path: path, "jsonCore.repository must be the pinned swift-json repository"))
        }
        if jsonCore.version != "2.5.3" {
            findings.append(finding("jsonCore.version", path: path, "jsonCore.version must be 2.5.3"))
        }
        if jsonCore.product != "IkigaJSONCore" || jsonCore.module != "_JSONCore" || jsonCore.packageName != "IkigaJSON" {
            findings.append(finding("jsonCore.identity", path: path, "jsonCore must identify IkigaJSONCore/_JSONCore with package name IkigaJSON"))
        }
        if !isRevision(jsonCore.revision) {
            findings.append(finding("jsonCore.revision", path: path, "jsonCore.revision must be a 40-character hexadecimal SHA"))
        }
        validateRelativePath(jsonCore.sourcePath, rule: "jsonCore.sourcePath", findings: &findings)
        validateRelativePath(jsonCore.lockPath, rule: "jsonCore.lockPath", findings: &findings)
    }

    private func validateWireBoundary(findings: inout [AxolotyRepositoryAuthorityFinding]) {
        let manifestPath = "Packages/AxolotyWire/Package.swift"
        guard let manifest = read(manifestPath) else { return }
        let packageBlocks = declarationBlocks(kind: "package", in: manifest)
        let expectedPackage = packageBlocks.first {
            firstCapture(#"\burl\s*:\s*"([^"]+)"#, in: $0) == "https://github.com/phynics/swift-json.git"
        }
        if packageBlocks.count != 1 || expectedPackage == nil ||
            firstCapture(#"\bexact\s*:\s*"([^"]+)"#, in: expectedPackage ?? "") != "2.5.3" ||
            !(expectedPackage ?? "").contains("traits: []") {
            findings.append(finding("wire.dependency", path: manifestPath, "AxolotyWire must declare only exact swift-json 2.5.3 with disabled traits"))
        }
        guard let target = declarationBlock(kind: "target", name: "AxolotyWire", in: manifest) else {
            findings.append(finding("wire.target", path: manifestPath, "AxolotyWire target is missing"))
            return
        }
        if firstCapture(#"\bpath\s*:\s*"([^"]+)"#, in: target) != "Sources/AxolotyWire" {
            findings.append(finding("wire.targetPath", path: manifestPath, "AxolotyWire target path must be Sources/AxolotyWire"))
        }
        guard let dependencies = labeledArray("dependencies", in: target) else {
            findings.append(finding("wire.product", path: manifestPath, "AxolotyWire target dependencies are missing"))
            return
        }
        let products = declarationBlocks(kind: "product", in: dependencies)
        let nonProductDependencies = products.reduce(dependencies) { result, product in
            result.replacingOccurrences(of: product, with: "")
        }.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !"[],".unicodeScalars.contains(scalar)
        }
        if products.count != 1 || nonProductDependencies ||
            firstCapture(#"\bname\s*:\s*"([^"]+)"#, in: products.first ?? "") != "IkigaJSONCore" ||
            firstCapture(#"\bpackage\s*:\s*"([^"]+)"#, in: products.first ?? "") != "swift-json" {
            findings.append(finding("wire.product", path: manifestPath, "AxolotyWire must depend only on swift-json product IkigaJSONCore"))
        }
        let imports = swiftImports(in: root.appendingPathComponent("Packages/AxolotyWire/Sources/AxolotyWire"))
        let unexpected = imports.subtracting(["_JSONCore"])
        if !unexpected.isEmpty || imports.isEmpty {
            findings.append(finding("wire.import", path: "Packages/AxolotyWire/Sources/AxolotyWire", "AxolotyWire may import only _JSONCore (found \(unexpected.sorted().joined(separator: ", ")))"))
        }
    }

    private func validateLocks(_ jsonCore: JSONCore, findings: inout [AxolotyRepositoryAuthorityFinding]) {
        let rootLock = "Package.resolved"
        validateLock(jsonCore, path: jsonCore.lockPath, findings: &findings, rulePrefix: "lock.standalone")
        validateLock(jsonCore, path: rootLock, findings: &findings, rulePrefix: "lock.root")
        guard let standalone = lockPin(jsonCore, path: jsonCore.lockPath),
              let root = lockPin(jsonCore, path: rootLock) else { return }
        if standalone.revision != root.revision || standalone.version != root.version {
            findings.append(finding("lock.agreement", path: rootLock, "root and standalone swift-json locks must agree exactly"))
        }
    }

    private func validateLock(
        _ jsonCore: JSONCore,
        path: String,
        findings: inout [AxolotyRepositoryAuthorityFinding],
        rulePrefix: String
    ) {
        guard let pin = lockPin(jsonCore, path: path) else {
            findings.append(finding(rulePrefix, path: path, "lock must contain a swift-json pin"))
            return
        }
        if pin.revision != jsonCore.revision {
            findings.append(finding(rulePrefix + ".revision", path: path, "swift-json lock revision must equal the contract revision"))
        }
        if pin.version != jsonCore.version {
            findings.append(finding(rulePrefix + ".version", path: path, "swift-json lock version must equal the contract version"))
        }
        if pin.location != jsonCore.repository {
            findings.append(finding(rulePrefix + ".repository", path: path, "swift-json lock location must equal the contract repository"))
        }
    }

    private func lockPin(_ jsonCore: JSONCore, path: String) -> (revision: String, version: String, location: String)? {
        guard let data = readData(path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = object["pins"] as? [[String: Any]] else { return nil }
        guard let pin = pins.first(where: { stringValue($0["identity"]) == jsonCore.identity }),
              let state = pin["state"] as? [String: Any],
              let revision = stringValue(state["revision"]),
              let version = stringValue(state["version"]),
              let location = stringValue(pin["location"]) else { return nil }
        return (revision, version, location)
    }

    private func validateRelativePath(
        _ path: String,
        rule: String,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let valid = !path.isEmpty && !path.hasPrefix("/") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
        if !valid {
            findings.append(finding(rule, path: path, "path must be a non-empty safe relative path"))
        }
    }

    private func directoryContainsSwift(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" && isWithinRepository(fileURL) {
            return true
        }
        return false
    }

    private func sourceTreeIsContained(_ url: URL) -> Bool {
        guard isWithinRepository(url),
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        for case let fileURL as URL in enumerator where !isWithinRepository(fileURL) {
            return false
        }
        return true
    }

    private func swiftImports(in directory: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var imports = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" && isWithinRepository(fileURL) {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for capture in allCaptures(#"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: text, options: [.anchorsMatchLines]) {
                imports.insert(capture)
            }
        }
        return imports
    }

    private func packageName(in manifest: String) -> String? {
        firstCapture(#"\blet\s+package\s*=\s*Package\s*\(\s*name\s*:\s*"([^"]+)"#, in: manifest)
    }

    private func libraryProduct(name: String, in manifest: String) -> Bool {
        declarationBlocks(kind: "library", in: manifest).contains {
            firstCapture(#"\bname\s*:\s*"([^"]+)"#, in: $0) == name &&
                firstCapture(#"\btargets\s*:\s*\[\s*"([^"]+)"#, in: $0) == name
        }
    }

    private func declarationBlock(kind: String, name: String, in text: String) -> String? {
        declarationBlocks(kind: kind, in: text).first {
            firstCapture(#"\bname\s*:\s*"([^"]+)"#, in: $0) == name
        }
    }

    private func labeledArray(_ label: String, in text: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: label) + #"\s*:\s*\["#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(location: 0, length: (text as NSString).length)
              ) else { return nil }
        let nsText = text as NSString
        let open = match.range.location + match.range.length - 1
        var depth = 0
        var quoted = false
        var escaped = false
        for index in open..<nsText.length {
            let character = nsText.substring(with: NSRange(location: index, length: 1))
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return nsText.substring(with: NSRange(location: open, length: index - open + 1))
                }
            }
        }
        return nil
    }

    private func declarationBlocks(kind: String, in text: String) -> [String] {
        let pattern = "\\." + NSRegularExpression.escapedPattern(for: kind) + #"\s*\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var blocks: [String] = []
        for match in matches {
            let open = match.range.location + match.range.length - 1
            var depth = 0
            var quoted = false
            var escaped = false
            var close = nsText.length - 1
            for index in open..<nsText.length {
                let character = nsText.substring(with: NSRange(location: index, length: 1))
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" {
                    quoted = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        close = index
                        break
                    }
                }
            }
            blocks.append(nsText.substring(with: NSRange(location: match.range.location, length: close - match.range.location + 1)))
        }
        return blocks
    }

    private func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private func allCaptures(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return (text as NSString).substring(with: match.range(at: 1))
        }
    }

    private func read(_ path: String) -> String? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard isWithinRepository(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func readData(_ path: String) -> Data? {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard isWithinRepository(url) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func finding(_ rule: String, path: String?, _ message: String) -> AxolotyRepositoryAuthorityFinding {
        AxolotyRepositoryAuthorityFinding(rule: "embedded-contract.\(rule)", path: path, message: message)
    }

    private func sorted(_ findings: [AxolotyRepositoryAuthorityFinding]) -> [AxolotyRepositoryAuthorityFinding] {
        findings.sorted {
            ($0.path ?? "", $0.rule, $0.message) < ($1.path ?? "", $1.rule, $1.message)
        }
    }

    private func relativePath(_ url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    private func isWithinRepository(_ url: URL) -> Bool {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private static func resolve(path: String, relativeTo root: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    private func string(_ value: Any?, key: String, findings: inout [AxolotyRepositoryAuthorityFinding]) -> String? {
        guard let value = stringValue(value), !value.isEmpty else {
            findings.append(finding("field", path: relativePath(contractURL), "\(key) must be a non-empty string"))
            return nil
        }
        return value
    }

    private func stringArray(_ value: Any?, key: String, findings: inout [AxolotyRepositoryAuthorityFinding]) -> [String]? {
        guard let values = value as? [Any] else {
            findings.append(finding("field", path: relativePath(contractURL), "\(key) must be an array of strings"))
            return nil
        }
        let strings = values.compactMap { stringValue($0) }
        guard strings.count == values.count else {
            findings.append(finding("field", path: relativePath(contractURL), "\(key) must be an array of strings"))
            return nil
        }
        return strings
    }

    private func stringValue(_ value: Any?) -> String? { value as? String }
    private func integer(_ value: Any?) -> Int? { value as? Int }

    private func integer(
        _ value: Any?,
        key: String,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) -> Int? {
        guard let value = integer(value) else {
            findings.append(finding("field", path: relativePath(contractURL), "\(key) must be an integer"))
            return nil
        }
        return value
    }
    private func isRevision(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 70) ||
                (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}
