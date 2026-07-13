// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ErrorKit
import Testing
@testable import CoatySwift

@Suite
struct ErrorKitPolicyTests {
    @Test
    func testCoatySwiftErrorUsesThrowableMessages() {
        let error = CoatySwiftError.InvalidArgument("invalid topic")

        #expect(error.userFriendlyMessage == "invalid topic")
        #expect(ErrorKit.userFriendlyMessage(for: error) == "invalid topic")
    }

    @Test
    func testCoatySwiftErrorRemainsSourceCompatibleAsThrownError() {
        let error: any Error = CoatySwiftError.RuntimeError("boom")

        #expect((error as? CoatySwiftError)?.userFriendlyMessage == "boom")
    }
}
