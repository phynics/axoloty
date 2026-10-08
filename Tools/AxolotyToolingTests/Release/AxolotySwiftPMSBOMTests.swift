// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Test
func swiftPMSBOMPackagesMustMatchTheirResolvedVersions() throws {
    let resolved = Data(#"{"pins":[{"identity":"swift-nio","location":"https://github.com/apple/swift-nio.git","state":{"revision":"abc123","version":"2.101.2"}},{"identity":"errorkit","location":"https://github.com/FlineDev/ErrorKit.git","state":{"revision":"def456","version":"1.2.1"}}]}"#.utf8)
    let sbom = Data(#"{"bomFormat":"CycloneDX","components":[{"name":"swift-nio","purl":"pkg:swift/github.com/apple/swift-nio@2.101.2","pedigree":{"commits":[{"uid":"abc123"}]},"properties":[{"name":"swift-entity","value":"swift-package"}]}]}"#.utf8)

    try AxolotySwiftPMSBOMValidator().validate(sbom: sbom, resolved: resolved)
}

@Test
func swiftPMSBOMIgnoresItsRootPackage() throws {
    // SwiftPM lists the root package among the components, named after the
    // checkout directory, and Package.resolved never pins it.
    let resolved = Data(#"{"pins":[{"identity":"swift-nio","location":"https://github.com/apple/swift-nio.git","state":{"revision":"abc123","version":"2.101.2"}}]}"#.utf8)
    let root = #"{"name":"workspace","purl":"pkg:swift/github.com/phynics/workspace@0123abc","properties":[{"name":"swift-entity","value":"swift-package"}]}"#
    let dependency = #"{"name":"swift-nio","purl":"pkg:swift/github.com/apple/swift-nio@2.101.2","pedigree":{"commits":[{"uid":"abc123"}]},"properties":[{"name":"swift-entity","value":"swift-package"}]}"#
    let sbom = Data(#"{"bomFormat":"CycloneDX","metadata":{"component":{"name":"workspace","purl":"pkg:swift/github.com/phynics/workspace@0123abc"}},"components":["#.utf8 + Data(root.utf8) + Data(",".utf8) + Data(dependency.utf8) + Data("]}".utf8))

    try AxolotySwiftPMSBOMValidator().validate(sbom: sbom, resolved: resolved)

    // Without the metadata subject, the same root component is unpinned.
    let anonymous = Data(#"{"bomFormat":"CycloneDX","components":["#.utf8 + Data(root.utf8) + Data(",".utf8) + Data(dependency.utf8) + Data("]}".utf8))
    #expect(throws: AxolotySwiftPMSBOMError.packageMismatch(["workspace"])) {
        try AxolotySwiftPMSBOMValidator().validate(sbom: anonymous, resolved: resolved)
    }
}

@Test
func swiftPMSBOMRejectsAnUnpinnedOrStaleSBOMPackage() throws {
    let resolved = Data(#"{"pins":[{"identity":"swift-nio","location":"https://github.com/apple/swift-nio.git","state":{"revision":"abc123","version":"2.101.2"}}]}"#.utf8)
    let stale = Data(#"{"bomFormat":"CycloneDX","components":[{"name":"swift-nio","purl":"pkg:swift/github.com/apple/swift-nio@2.100.0","pedigree":{"commits":[{"uid":"abc123"}]},"properties":[{"name":"swift-entity","value":"swift-package"}]}]}"#.utf8)
    let staleRevision = Data(#"{"bomFormat":"CycloneDX","components":[{"name":"swift-nio","purl":"pkg:swift/github.com/apple/swift-nio@2.101.2","pedigree":{"commits":[{"uid":"different-revision"}]},"properties":[{"name":"swift-entity","value":"swift-package"}]}]}"#.utf8)
    let staleLocation = Data(#"{"bomFormat":"CycloneDX","components":[{"name":"swift-nio","purl":"pkg:swift/github.com/example/swift-nio@2.101.2","pedigree":{"commits":[{"uid":"abc123"}]},"properties":[{"name":"swift-entity","value":"swift-package"}]}]}"#.utf8)
    let unpinned = Data(#"{"bomFormat":"CycloneDX","components":[{"name":"other-package","purl":"pkg:swift/github.com/example/other-package@1.0.0","properties":[{"name":"swift-entity","value":"swift-package"}]}]}"#.utf8)

    for sbom in [stale, staleRevision, staleLocation, unpinned] {
        let expected: AxolotySwiftPMSBOMError = .packageMismatch([
            sbom == unpinned ? "other-package" : "swift-nio",
        ])
        #expect(throws: expected) {
            try AxolotySwiftPMSBOMValidator().validate(sbom: sbom, resolved: resolved)
        }
    }
}

@Test
func swiftPMSBOMRejectsMalformedDocument() {
    #expect(throws: AxolotySwiftPMSBOMError.malformedSBOM) {
        try AxolotySwiftPMSBOMValidator().validate(
            sbom: Data(#"{"bomFormat":"SPDX"}"#.utf8),
            resolved: Data(#"{"pins":[]}"#.utf8)
        )
    }
}
