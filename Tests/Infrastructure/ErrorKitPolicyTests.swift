// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import ErrorKit
import Testing

struct ErrorKitPolicyTests {
    @Test
    func axolotyErrorUsesThrowableMessages() {
        let error = AxolotyError.InvalidArgument("invalid topic")

        #expect(error.userFriendlyMessage == "invalid topic")
        #expect(ErrorKit.userFriendlyMessage(for: error) == "invalid topic")
    }

    @Test
    func axolotyErrorRemainsSourceCompatibleAsThrownError() {
        let error: any Error = AxolotyError.RuntimeError("boom")

        #expect((error as? AxolotyError)?.userFriendlyMessage == "boom")
    }

    @Test
    func caughtCaseDelegatesToWrappedErrorMessage() {
        let wrapped = AxolotyError.caught(AxolotyError.DecodingFailure("bad payload"))

        #expect(wrapped.userFriendlyMessage == "bad payload")
        #expect(ErrorKit.userFriendlyMessage(for: wrapped) == "bad payload")
    }

    @Test
    func catchWrapsForeignErrorsAndPassesThroughValues() throws {
        struct ForeignError: Throwable {
            let userFriendlyMessage = "foreign failure"
        }

        let value = try AxolotyError.catch { 42 }
        #expect(value == 42)

        do {
            _ = try AxolotyError.catch { () -> Int in throw ForeignError() }
            Issue.record("Expected AxolotyError.catch to rethrow")
        } catch {
            guard case let .caught(inner) = error else {
                Issue.record("Expected a caught case, got \(error)")
                return
            }
            #expect(inner is ForeignError)
            #expect(error.userFriendlyMessage == "foreign failure")
        }
    }
}
