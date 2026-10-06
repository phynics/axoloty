// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Test("every Zenoh host pins its own release archives by target triple")
func zenohHostsPinDistinctArchives() {
    for host in AxolotyZenohHost.allCases {
        #expect(host.routerArchive == "zenoh-1.10.0-\(host.rawValue)-standalone.zip")
        #expect(host.cArchive == "zenoh-c-1.10.0-\(host.rawValue)-standalone.zip")
        for checksum in [host.routerChecksum, host.cChecksum] {
            #expect(checksum.count == 64)
            #expect(checksum.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
    let checksums = AxolotyZenohHost.allCases.flatMap { [$0.routerChecksum, $0.cChecksum] }
    #expect(Set(checksums).count == checksums.count)
}

@Test("Darwin zenoh-c installations add an explicit runtime search path")
func zenohDarwinInstallationAddsRuntimeSearchPath() {
    let root = URL(fileURLWithPath: "/tmp/zenoh-c")
    let darwin = makeInstallation(host: .macOSARM64, root: root)
    #expect(darwin.swiftLinkerArguments == ["-Xlinker", "-rpath", "-Xlinker", "/tmp/zenoh-c/lib"])
    #expect(darwin.cCompilerArguments == [
        "-I/tmp/zenoh-c/include", "-L/tmp/zenoh-c/lib", "-lzenohc", "-Wl,-rpath,/tmp/zenoh-c/lib",
    ])

    let linux = makeInstallation(host: .linuxX86_64, root: root)
    #expect(linux.swiftLinkerArguments.isEmpty)
    #expect(linux.cCompilerArguments == ["-I/tmp/zenoh-c/include", "-L/tmp/zenoh-c/lib", "-lzenohc"])
    #expect(linux.environment(extending: [:])["LD_LIBRARY_PATH"] == "/tmp/zenoh-c/lib")
}

@Test("an unsupported host fails before provisioning any archive")
func zenohUnsupportedHostFailsBeforeProvisioning() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-zenoh-unsupported-\(UUID().uuidString)")
    let toolchain = AxolotyZenohToolchain(environment: [:], host: nil)

    do {
        _ = try toolchain.provisionZenohC(in: directory)
        Issue.record("an unsupported host provisioned zenoh-c")
    } catch {
        #expect(error.localizedDescription.contains(AxolotyZenohHost.supportedDescription))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

private func makeInstallation(host: AxolotyZenohHost, root: URL) -> AxolotyZenohCInstallation {
    AxolotyZenohCInstallation(
        host: host,
        pkgConfigDirectory: root.appending(path: "lib/pkgconfig"),
        includeDirectory: root.appending(path: "include"),
        libraryDirectory: root.appending(path: "lib")
    )
}
