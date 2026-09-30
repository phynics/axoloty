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
            if command.arguments.last == "--show-bin-path" {
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
func moduleMapContentsEscapeHeaderPathCharacters() {
    let expected = "module CAxolotyZenoh {\n" +
        "    header \"/tmp/core/with \\\"quote\\\"/and\\\\slash/axoloty_zenoh.h\"\n" +
        "    export *\n}\n"
    #expect(AxolotyEmbeddedConsumerPreparation.moduleMapContents(
        module: "CAxolotyZenoh",
        headerPath: "/tmp/core/with \"quote\"/and\\slash/axoloty_zenoh.h"
    ) == expected)
}
