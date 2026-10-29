// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private struct EmbeddedConsumerPreparationRunner: AxolotyCheckCommandRunning {
    let coreRoot: URL
    let macroBin: URL
    let jsonRevision: String

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        switch command.executable {
        case "git":
            if command.arguments.last == "--show-toplevel" {
                return .init(exitCode: 0, standardOutput: coreRoot.path + "\n")
            }
            if command.arguments.last == "HEAD^{commit}" {
                let checkout = command.arguments.count > 1 ? command.arguments[1] : ""
                let revision = checkout.contains("/checkouts/swift-json")
                    ? jsonRevision
                    : String(repeating: "a", count: 40)
                return .init(exitCode: 0, standardOutput: revision + "\n")
            }
            if command.arguments.contains("status") {
                return .init(exitCode: 0)
            }
            return .init(exitCode: 1, standardError: "unexpected git command")
        case "swift":
            if command.arguments.first == "build",
               command.arguments.contains("--target"),
               !command.arguments.contains("AxolotyStaticRuntime") {
                return .init(exitCode: 1, standardError: "preparation must build the static runtime macro prerequisite")
            }
            if command.arguments.contains("--show-bin-path") {
                return .init(exitCode: 0, standardOutput: macroBin.path + "\n")
            }
            return .init(exitCode: 0)
        default:
            return .init(exitCode: 1, standardError: "unexpected command")
        }
    }
}

private struct LegacyConsumerReport: Decodable {
    struct PortablePackage: Decodable {
        let name: String
        let sourcePath: String
    }

    let schemaVersion: Int
    let portablePackages: [PortablePackage]
}

@Test
func preparationReportsZenohCoreWithoutChangingLegacyPackageOutput() throws {
    let fixture = try makeEmbeddedContractFixture()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-scratch-" + UUID().uuidString)
    let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-report-" + UUID().uuidString + ".json")
    let secondReportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-report-" + UUID().uuidString + ".json")
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: reportURL)
        try? FileManager.default.removeItem(at: secondReportURL)
    }

    let macroBin = scratch.appendingPathComponent("bin")
    let jsonCore = scratch.appendingPathComponent("checkouts/swift-json/Sources/_JSONCore")
    try FileManager.default.createDirectory(at: macroBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: jsonCore, withIntermediateDirectories: true)
    let macroExecutable = macroBin.appendingPathComponent("AxolotyStaticRuntimeMacrosImplementation-tool")
    try Data().write(to: macroExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macroExecutable.path)

    let contractData = try Data(contentsOf: fixture.appendingPathComponent("docs/embedded-consumer-contract.json"))
    let contract = try JSONSerialization.jsonObject(with: contractData) as! [String: Any]
    let jsonRevision = (contract["jsonCore"] as! [String: Any])["revision"] as! String
    let runner = EmbeddedConsumerPreparationRunner(coreRoot: fixture, macroBin: macroBin, jsonRevision: jsonRevision)
    let preparation = AxolotyEmbeddedConsumerPreparation(
        environment: [
            "AXOLOTY_SOURCE_DIR": fixture.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ],
        commandRunner: runner
    )

    for output in [reportURL, secondReportURL] {
        let result = preparation.run(arguments: ["--scratch", scratch.path, "--output", output.path])
        #expect(result.exitCode == 0)
    }

    let reportData = try Data(contentsOf: reportURL)
    let report = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
    #expect(report["schemaVersion"] as? Int == 1)
    #expect(report["status"] as? String == "prepared")
    #expect(report["selectedWireProfiles"] as? [String] == ["coaty3JSON", "axoloty1CBOR"])
    let packageReports = report["portablePackages"] as! [[String: Any]]
    #expect(packageReports.compactMap { $0["name"] as? String } == [
        "AxolotyWire",
        "AxolotyObjectModel",
        "AxolotyProtocol",
        "AxolotyCoatyModels",
        "AxolotyStaticRuntime",
    ])
    #expect(packageReports.compactMap { $0["sourcePath"] as? String } == [
        "Packages/AxolotyWire/Sources/AxolotyWire",
        "Packages/AxolotyObjectModel/Sources/AxolotyObjectModel",
        "Packages/AxolotyProtocol/Sources/AxolotyProtocol",
        "Packages/AxolotyCoatyModels/Sources/AxolotyCoatyModels",
        "Packages/AxolotyStaticRuntime/Sources/AxolotyStaticRuntime",
    ].map { fixture.appendingPathComponent($0).path })

    let zenoh = report["zenohCore"] as! [String: Any]
    let secondReport = try JSONSerialization.jsonObject(with: Data(contentsOf: secondReportURL)) as! [String: Any]
    let secondZenoh = secondReport["zenohCore"] as! [String: Any]
    let expectedSource = fixture.appendingPathComponent("Packages/AxolotyZenoh/Sources/AxolotyZenohCore").path
    let expectedHeader = fixture.appendingPathComponent(
        "Packages/AxolotyZenoh/Sources/CAxolotyZenoh/include/axoloty_zenoh.h"
    )
    let moduleMap = URL(fileURLWithPath: zenoh["moduleMap"] as! String)
    #expect(zenoh["module"] as? String == "AxolotyZenohCore")
    #expect(zenoh["sourceDir"] as? String == expectedSource)
    #expect(zenoh["facadeModule"] as? String == "CAxolotyZenoh")
    #expect(zenoh["facadeHeader"] as? String == expectedHeader.path)
    #expect(zenoh["facadeHeaderSHA256"] as? String == AxolotySHA256().hash(try Data(contentsOf: expectedHeader)))
    #expect(moduleMap.path == scratch.appendingPathComponent("CAxolotyZenoh/module.modulemap").path)
    #expect(try String(contentsOf: moduleMap, encoding: .utf8) == AxolotyEmbeddedConsumerPreparation.moduleMapContents(
        module: "CAxolotyZenoh",
        headerPath: expectedHeader.path
    ))
    #expect(zenoh["moduleMap"] as? String == secondZenoh["moduleMap"] as? String)
    let secondModuleMap = URL(fileURLWithPath: secondZenoh["moduleMap"] as! String)
    #expect(secondModuleMap == moduleMap)
    #expect(try Data(contentsOf: moduleMap) == Data(contentsOf: secondModuleMap))

    let legacyReport = try JSONDecoder().decode(LegacyConsumerReport.self, from: reportData)
    #expect(legacyReport.schemaVersion == 1)
    #expect(legacyReport.portablePackages.map(\.name) == packageReports.compactMap { $0["name"] as? String })
}

@Test
func preparationAcceptsCBOROnlyContractWithoutJSONCore() throws {
    let fixture = try makeEmbeddedContractFixture()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-scratch-" + UUID().uuidString)
    let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-report-" + UUID().uuidString + ".json")
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: reportURL)
    }

    // Rewrite the fixture contract to declare only the mandatory CBOR profile
    // and drop `jsonCore`, the shape the validator already accepts.
    let contractURL = fixture.appendingPathComponent("docs/embedded-consumer-contract.json")
    var contract = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as! [String: Any]
    var profiles = contract["wireProfiles"] as! [[String: Any]]
    let cborIndex = profiles.firstIndex { ($0["id"] as? String) == "axoloty1CBOR" }!
    profiles[cborIndex]["default"] = true
    contract["wireProfiles"] = [profiles[cborIndex]]
    contract.removeValue(forKey: "jsonCore")
    try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys]).write(to: contractURL)

    let macroBin = scratch.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: macroBin, withIntermediateDirectories: true)
    let macroExecutable = macroBin.appendingPathComponent("AxolotyStaticRuntimeMacrosImplementation-tool")
    try Data().write(to: macroExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macroExecutable.path)

    // The swift-json checkout is intentionally absent. Preparation must not
    // require or report it.
    let runner = EmbeddedConsumerPreparationRunner(coreRoot: fixture, macroBin: macroBin, jsonRevision: "")
    let preparation = AxolotyEmbeddedConsumerPreparation(
        environment: [
            "AXOLOTY_SOURCE_DIR": fixture.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ],
        commandRunner: runner
    )

    let result = preparation.run(arguments: ["--scratch", scratch.path, "--output", reportURL.path])
    #expect(result.exitCode == 0, "\(result.standardError)")

    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
    #expect(report["schemaVersion"] as? Int == 1)
    #expect(report["status"] as? String == "prepared")
    #expect(report["jsonCore"] == nil)
    #expect((report["portablePackages"] as? [[String: Any]])?.count == 5)
}

@Test
func preparationSelectsCBORFromDualProfileContractWithoutJSONCore() throws {
    let fixture = try makeEmbeddedContractFixture()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-cbor-select-" + UUID().uuidString)
    let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-cbor-report-" + UUID().uuidString + ".json")
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: reportURL)
    }

    let macroBin = scratch.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: macroBin, withIntermediateDirectories: true)
    let macroExecutable = macroBin.appendingPathComponent("AxolotyStaticRuntimeMacrosImplementation-tool")
    try Data().write(to: macroExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macroExecutable.path)

    let contractData = try Data(contentsOf: fixture.appendingPathComponent("docs/embedded-consumer-contract.json"))
    let contract = try JSONSerialization.jsonObject(with: contractData) as! [String: Any]
    let jsonRevision = (contract["jsonCore"] as! [String: Any])["revision"] as! String
    let runner = EmbeddedConsumerPreparationRunner(
        coreRoot: fixture,
        macroBin: macroBin,
        jsonRevision: jsonRevision
    )
    let preparation = AxolotyEmbeddedConsumerPreparation(
        environment: [
            "AXOLOTY_SOURCE_DIR": fixture.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ],
        commandRunner: runner
    )

    let result = preparation.run(arguments: [
        "--scratch", scratch.path,
        "--output", reportURL.path,
        "--profile", "axoloty1CBOR",
    ])
    #expect(result.exitCode == 0, "\(result.standardError)")

    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
    #expect(report["selectedWireProfiles"] as? [String] == ["axoloty1CBOR"])
    #expect(report["jsonCore"] == nil)
    #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("checkouts/swift-json").path) == false)
}

@Test
func preparationRejectsUndeclaredWireProfileSelection() throws {
    let fixture = try makeEmbeddedContractFixture()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-invalid-profile-" + UUID().uuidString)
    let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("axoloty-consumer-preparation-invalid-profile-" + UUID().uuidString + ".json")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: reportURL)
    }
    let preparation = AxolotyEmbeddedConsumerPreparation(
        environment: ["AXOLOTY_SOURCE_DIR": fixture.path],
        commandRunner: EmbeddedConsumerPreparationRunner(
            coreRoot: fixture,
            macroBin: scratch,
            jsonRevision: ""
        )
    )
    let result = preparation.run(arguments: [
        "--scratch", scratch.path,
        "--output", reportURL.path,
        "--profile", "axoloty4CBOR",
    ])
    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("wire profile is not declared"))
}

@Test
func moduleMapContentsEscapeHeaderPathCharacters() {
    let expected = "module CAxolotyZenoh {\n" +
        "    header \"/tmp/core/with \\\"quote\\\"/and\\\\slash/axoloty_zenoh.h\"\n" +
        "    export *\n}\n"
    #expect(AxolotyEmbeddedConsumerPreparation.moduleMapContents(
        module: "CAxolotyZenoh",
        headerPath: "/tmp/core/with \"quote\"/and\\slash/axoloty_zenoh.h"
    ) == expected)
}
