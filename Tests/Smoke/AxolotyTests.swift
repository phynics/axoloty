//  Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  AxolotyTests.swift
//  Axoloty
//
//

@testable import Axoloty
import Testing

@Suite
struct AxolotyTests {

    @Test
    func testPublicAPIsAreReachable() throws {
        let uuid = try #require(CoatyUUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        #expect(uuid.string == "00000000-0000-4000-8000-000000000001")
        #expect(CommunicationTopic.matches("a/b/c", "a/+/c"))
    }

}
