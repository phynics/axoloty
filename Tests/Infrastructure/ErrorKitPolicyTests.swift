// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ErrorKit
import Testing
@testable import Axoloty

@Suite
struct ErrorKitPolicyTests {
    @Test
    func testAxolotyErrorUsesThrowableMessages() {
        let error = AxolotyError.InvalidArgument("invalid topic")

        #expect(error.userFriendlyMessage == "invalid topic")
        #expect(ErrorKit.userFriendlyMessage(for: error) == "invalid topic")
    }

    @Test
    func testAxolotyErrorRemainsSourceCompatibleAsThrownError() {
        let error: any Error = AxolotyError.RuntimeError("boom")

        #expect((error as? AxolotyError)?.userFriendlyMessage == "boom")
    }
}
