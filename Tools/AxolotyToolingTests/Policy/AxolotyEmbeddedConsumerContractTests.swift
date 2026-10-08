// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private func embeddedContractRepositoryRoot(_ file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent() // Policy
        .deletingLastPathComponent() // AxolotyToolingTests
        .deletingLastPathComponent() // Tools
        .deletingLastPathComponent() // checkout root
}

@Test
func repositoryAuthorityPassesForCheckoutEmbeddedConsumerContract() {
    let root = embeddedContractRepositoryRoot()
    let findings = AxolotyEmbeddedConsumerContractValidator(root: root).validate()
    #expect(findings.isEmpty, "\(findings)")
}

@Test
func embeddedConsumerContractExportsZenohCoreBesideTheUnchangedFiveModules() throws {
    let root = embeddedContractRepositoryRoot()
    let data = try Data(contentsOf: root.appendingPathComponent("docs/embedded-consumer-contract.json"))
    let contract = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let packages = try #require(contract["portablePackages"] as? [[String: Any]])

    #expect(packages.compactMap { $0["package"] as? String } == [
        "AxolotyWire",
        "AxolotyObjectModel",
        "AxolotyProtocol",
        "AxolotyCoatyModels",
        "AxolotyStaticRuntime",
    ])

    let zenohCore = try #require(contract["zenohCore"] as? [String: Any])
    #expect(zenohCore["package"] as? String == "AxolotyZenoh")
    #expect(zenohCore["packagePath"] as? String == "Packages/AxolotyZenoh")
    #expect(zenohCore["target"] as? String == "AxolotyZenohCore")
    #expect(zenohCore["module"] as? String == "AxolotyZenohCore")
    #expect(zenohCore["sourcePath"] as? String == "Packages/AxolotyZenoh/Sources/AxolotyZenohCore")
    #expect(zenohCore["facadeModule"] as? String == "CAxolotyZenoh")
    #expect(zenohCore["facadeHeaderPath"] as? String ==
        "Packages/AxolotyZenoh/Sources/CAxolotyZenoh/include/axoloty_zenoh.h")

    let findings = AxolotyEmbeddedConsumerContractValidator(root: root).validate()
    #expect(findings.isEmpty, "\(findings)")
}

@Test
func repositoryAuthorityRejectsEmbeddedZenohPathAndTargetDrift() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let contractURL = fixture.appendingPathComponent("docs/embedded-consumer-contract.json")
    var contract = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as! [String: Any]
    var zenohCore = contract["zenohCore"] as! [String: Any]

    zenohCore["sourcePath"] = "../escape"
    contract["zenohCore"] = zenohCore
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)
    let sourcePathFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(sourcePathFindings.contains { $0.rule == "embedded-contract.zenohCore.sourcePath" })

    zenohCore["sourcePath"] = "Packages/AxolotyZenoh/Sources/AxolotyZenohCore"
    zenohCore["facadeHeaderPath"] = "Packages/AxolotyZenoh/../outside.h"
    contract["zenohCore"] = zenohCore
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)
    let headerPathFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(headerPathFindings.contains { $0.rule == "embedded-contract.zenohCore.facadeHeaderPath" })

    zenohCore["facadeHeaderPath"] = "Packages/AxolotyZenoh/Sources/CAxolotyZenoh/include/axoloty_zenoh.h"
    zenohCore["target"] = "AxolotyZenoh"
    contract["zenohCore"] = zenohCore
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)
    let targetFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(targetFindings.contains { $0.rule == "embedded-contract.zenohCore.target" })
}

@Test
func repositoryAuthorityPassesForCheckoutRejectingEmbeddedContractSchemaAndPathMutations() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let contractURL = fixture.appendingPathComponent("docs/embedded-consumer-contract.json")
    var contract = try JSONSerialization.jsonObject(
        with: Data(contentsOf: contractURL)
    ) as! [String: Any]
    contract["schemaVersion"] = 2
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)

    let schemaFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(schemaFindings.contains { $0.rule == "embedded-contract.contract.schema" })

    contract["schemaVersion"] = 1
    var packages = contract["portablePackages"] as! [[String: Any]]
    packages[0]["sourcePath"] = "../escape"
    contract["portablePackages"] = packages
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)

    let pathFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(pathFindings.contains { $0.rule == "embedded-contract.packages.sourcePath" })

    packages[0]["sourcePath"] = "Packages/AxolotyWire/Sources"
    contract["portablePackages"] = packages
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)

    let targetFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(targetFindings.contains { $0.rule == "embedded-contract.packages.targetPath" })
    #expect(targetFindings.contains { $0.rule == "embedded-contract.packages.rootTargetPath" })

    let wireManifestURL = fixture.appendingPathComponent("Packages/AxolotyWire/Package.swift")
    let wireManifest = try String(contentsOf: wireManifestURL, encoding: .utf8)
        .replacingOccurrences(
            of: "dependencies: [\n                .product",
            with: "dependencies: [\n                \"InjectedTarget\",\n                .product"
        )
    try Data(wireManifest.utf8).write(to: wireManifestURL)
    let dependencyFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(dependencyFindings.contains { $0.rule == "embedded-contract.wire.product" })

    let rootManifestURL = fixture.appendingPathComponent("Package.swift")
    let rootManifest = try String(contentsOf: rootManifestURL, encoding: .utf8)
        .replacingOccurrences(of: "swift-tools-version:6.4", with: "swift-tools-version:6.3")
        .replacingOccurrences(of: "swiftLanguageModes: [.v6]", with: "swiftLanguageModes: [.v5]")
    try Data(rootManifest.utf8).write(to: rootManifestURL)
    let rootManifestFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(rootManifestFindings.contains { $0.rule == "embedded-contract.root.toolsVersion" })
    #expect(rootManifestFindings.contains { $0.rule == "embedded-contract.root.languageMode" })
}

@Test
func repositoryAuthorityPassesForCheckoutRejectingEmbeddedContractSwiftJSONLockDisagreement() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let lockURL = fixture.appendingPathComponent("Package.resolved")
    var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as! [String: Any]
    var pins = lock["pins"] as! [[String: Any]]
    let index = pins.firstIndex { ($0["identity"] as? String) == "swift-json" }!
    var pin = pins[index]
    var state = pin["state"] as! [String: Any]
    state["revision"] = String(repeating: "0", count: 40)
    pin["state"] = state
    pins[index] = pin
    lock["pins"] = pins
    try JSONSerialization.data(withJSONObject: lock, options: [.sortedKeys]).write(to: lockURL)

    let findings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(findings.contains { $0.rule == "embedded-contract.lock.root.revision" })
    #expect(findings.contains { $0.rule == "embedded-contract.lock.agreement" })
}

@Test
func repositoryAuthorityPassesForCheckoutRejectingEmbeddedContractModulePolicyDrift() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let policyURL = fixture.appendingPathComponent("docs/module-policy.yml")
    var policy = try JSONSerialization.jsonObject(
        with: Data(contentsOf: policyURL)
    ) as! [String: Any]
    var targets = policy["targets"] as! [[String: Any]]
    let wireIndex = targets.firstIndex { ($0["name"] as? String) == "AxolotyWire" }!
    targets[wireIndex]["platformClass"] = "host"
    policy["targets"] = targets
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: policyURL)

    let findings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(findings.contains {
        $0.rule == "embedded-contract.packages.modulePolicy" &&
            $0.message.contains("AxolotyWire must use platformClass portable")
    })
}

@Test
func repositoryAuthorityRejectsEmbeddedZenohModulePolicyDrift() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let policyURL = fixture.appendingPathComponent("docs/module-policy.yml")
    var policy = try JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as! [String: Any]
    var targets = policy["targets"] as! [[String: Any]]
    let zenohIndex = targets.firstIndex { ($0["name"] as? String) == "AxolotyZenohCore" }!
    targets[zenohIndex]["platformClass"] = "host"
    policy["targets"] = targets
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: policyURL)

    let findings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(findings.contains {
        $0.rule == "embedded-contract.zenohCore.modulePolicy" &&
            $0.message.contains("AxolotyZenohCore must use the adapter role and the portable platform class")
    })
}

@Test
func repositoryAuthorityRejectsEmbeddedZenohModuleRoleDrift() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let policyURL = fixture.appendingPathComponent("docs/module-policy.yml")
    var policy = try JSONSerialization.jsonObject(with: Data(contentsOf: policyURL)) as! [String: Any]
    var targets = policy["targets"] as! [[String: Any]]
    let zenohIndex = targets.firstIndex { ($0["name"] as? String) == "AxolotyZenohCore" }!
    targets[zenohIndex]["role"] = "portable"
    policy["targets"] = targets
    try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: policyURL)

    let findings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(findings.contains {
        $0.rule == "embedded-contract.zenohCore.modulePolicy" &&
            $0.message.contains("AxolotyZenohCore must use the adapter role and the portable platform class")
    })
}

@Test
func repositoryAuthorityPassesForCheckoutReportingEmbeddedContractCommandFailure() throws {
    let fixture = try makeEmbeddedContractFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let contractURL = fixture.appendingPathComponent("docs/embedded-consumer-contract.json")
    var contract = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as! [String: Any]
    contract["schemaVersion"] = 2
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)

    let dispatcher = AxolotyCommandDispatcher(
        environment: ["AXOLOTY_SOURCE_DIR": fixture.path],
        installSignalHandler: false
    )
    let result = dispatcher.run(arguments: [
        "repository", "validate", "--embedded-consumer-contract", "--format", "json",
    ])
    #expect(result.exitCode == 1)
    let report = try JSONDecoder().decode(
        AxolotyRepositoryAuthorityReport.self,
        from: Data(result.standardOutput.utf8)
    )
    #expect(report.findings.contains { $0.rule == "embedded-contract.contract.schema" })
}

@Test
func repositoryAuthorityPassesForCheckoutRejectingEmbeddedContractSymlinkEscape() throws {
    let fixture = try makeEmbeddedContractFixture()
    let fileManager = FileManager.default
    let externalSources = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-embedded-contract-external-" + UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: externalSources)
    }
    try FileManager.default.createDirectory(at: externalSources, withIntermediateDirectories: true)
    try Data("import _JSONCore\n".utf8).write(to: externalSources.appendingPathComponent("External.swift"))

    let wireSources = fixture.appendingPathComponent("Packages/AxolotyWire/Sources/AxolotyWire")
    try FileManager.default.createSymbolicLink(
        at: wireSources.appendingPathComponent("External.swift"),
        withDestinationURL: externalSources.appendingPathComponent("External.swift")
    )
    let nestedFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(nestedFindings.contains { $0.rule == "embedded-contract.packages.sourcePath" })

    try FileManager.default.removeItem(at: wireSources)
    try FileManager.default.createSymbolicLink(at: wireSources, withDestinationURL: externalSources)

    let findings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(findings.contains { $0.rule == "embedded-contract.packages.sourcePath" })

    let macroSources = fixture.appendingPathComponent(
        "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntimeMacrosImplementation"
    )
    try FileManager.default.removeItem(at: macroSources)
    try FileManager.default.createSymbolicLink(at: macroSources, withDestinationURL: externalSources)
    let macroFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(macroFindings.contains { $0.rule == "embedded-contract.macro.sourcePath" })

    let zenohSources = fixture.appendingPathComponent("Packages/AxolotyZenoh/Sources/AxolotyZenohCore")
    try fileManager.removeItem(at: zenohSources)
    try fileManager.createSymbolicLink(at: zenohSources, withDestinationURL: externalSources)
    let zenohSourceFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(zenohSourceFindings.contains { $0.rule == "embedded-contract.zenohCore.sourcePath" })
    try fileManager.removeItem(at: zenohSources)
    try fileManager.createDirectory(at: zenohSources, withIntermediateDirectories: true)
    try Data("struct ZenohCoreFixtureSource {}\n".utf8).write(
        to: zenohSources.appendingPathComponent("Fixture.swift")
    )

    let zenohHeader = fixture.appendingPathComponent(
        "Packages/AxolotyZenoh/Sources/CAxolotyZenoh/include/axoloty_zenoh.h"
    )
    try fileManager.removeItem(at: zenohHeader)
    try fileManager.createSymbolicLink(
        at: zenohHeader,
        withDestinationURL: externalSources.appendingPathComponent("External.swift")
    )
    let zenohHeaderFindings = AxolotyEmbeddedConsumerContractValidator(root: fixture).validate()
    #expect(zenohHeaderFindings.contains { $0.rule == "embedded-contract.zenohCore.facadeHeaderPath" })
}

func makeEmbeddedContractFixture() throws -> URL {
    let sourceRoot = embeddedContractRepositoryRoot()
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-embedded-contract-" + UUID().uuidString)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: fixture.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: fixture.appendingPathComponent("Packages"), withIntermediateDirectories: true)

    for file in ["Package.swift", "Package.resolved"] {
        try fileManager.copyItem(
            at: sourceRoot.appendingPathComponent(file),
            to: fixture.appendingPathComponent(file)
        )
    }
    try fileManager.copyItem(
        at: sourceRoot.appendingPathComponent("docs/embedded-consumer-contract.json"),
        to: fixture.appendingPathComponent("docs/embedded-consumer-contract.json")
    )
    try fileManager.copyItem(
        at: sourceRoot.appendingPathComponent("docs/module-policy.yml"),
        to: fixture.appendingPathComponent("docs/module-policy.yml")
    )
    for (package, sourceDirectory) in [
        ("AxolotyWire", "AxolotyWire"),
        ("AxolotyObjectModel", "AxolotyObjectModel"),
        ("AxolotyProtocol", "AxolotyProtocol"),
        ("AxolotyCoatyModels", "AxolotyCoatyModels"),
        ("AxolotyStaticRuntime", "AxolotyStaticRuntime"),
    ] {
        let sourcePackage = sourceRoot.appendingPathComponent("Packages/" + package)
        let fixturePackage = fixture.appendingPathComponent("Packages/" + package)
        try fileManager.createDirectory(at: fixturePackage, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: sourcePackage.appendingPathComponent("Package.swift"),
            to: fixturePackage.appendingPathComponent("Package.swift")
        )
        let fixtureSources = fixturePackage.appendingPathComponent("Sources/" + sourceDirectory)
        try fileManager.createDirectory(at: fixtureSources, withIntermediateDirectories: true)
        let fixtureSource = package == "AxolotyWire" ? "import _JSONCore\n" : "struct FixtureSource {}\n"
        try Data(fixtureSource.utf8).write(
            to: fixtureSources.appendingPathComponent("Fixture.swift")
        )
    }
    let zenohPackage = sourceRoot.appendingPathComponent("Packages/AxolotyZenoh")
    let fixtureZenohPackage = fixture.appendingPathComponent("Packages/AxolotyZenoh")
    try fileManager.createDirectory(at: fixtureZenohPackage, withIntermediateDirectories: true)
    try fileManager.copyItem(
        at: zenohPackage.appendingPathComponent("Package.swift"),
        to: fixtureZenohPackage.appendingPathComponent("Package.swift")
    )
    let zenohCoreSources = fixtureZenohPackage.appendingPathComponent("Sources/AxolotyZenohCore")
    try fileManager.createDirectory(at: zenohCoreSources, withIntermediateDirectories: true)
    try Data("struct ZenohCoreFixtureSource {}\n".utf8).write(
        to: zenohCoreSources.appendingPathComponent("Fixture.swift")
    )
    let facadeHeader = "Sources/CAxolotyZenoh/include/axoloty_zenoh.h"
    let fixtureFacadeHeader = fixtureZenohPackage.appendingPathComponent(facadeHeader)
    try fileManager.createDirectory(
        at: fixtureFacadeHeader.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try fileManager.copyItem(
        at: zenohPackage.appendingPathComponent(facadeHeader),
        to: fixtureFacadeHeader
    )
    let macroSources = fixture.appendingPathComponent(
        "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntimeMacrosImplementation"
    )
    try fileManager.createDirectory(at: macroSources, withIntermediateDirectories: true)
    try Data("struct FixtureMacro {}\n".utf8).write(to: macroSources.appendingPathComponent("Fixture.swift"))
    try fileManager.copyItem(
        at: sourceRoot.appendingPathComponent("Packages/AxolotyStaticRuntime/Package.resolved"),
        to: fixture.appendingPathComponent("Packages/AxolotyStaticRuntime/Package.resolved")
    )
    return fixture
}

@Test
func macroExecutableNamesAcceptBothBuildSystemSpellings() {
    // SwiftPM's native build system emits the "-tool" spelling the contract
    // declares; Swift Build emits the bare target name.
    #expect(
        AxolotyEmbeddedConsumerPreparation.macroExecutableNames(
            for: "AxolotyStaticRuntimeMacrosImplementation-tool"
        ) == [
            "AxolotyStaticRuntimeMacrosImplementation-tool",
            "AxolotyStaticRuntimeMacrosImplementation",
        ]
    )
}

@Test
func macroExecutableNamesLeaveAnUnsuffixedContractNameAlone() {
    #expect(
        AxolotyEmbeddedConsumerPreparation.macroExecutableNames(
            for: "AxolotyStaticRuntimeMacrosImplementation"
        ) == ["AxolotyStaticRuntimeMacrosImplementation"]
    )
}
