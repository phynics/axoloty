// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import ErrorKit
import Foundation
import Testing

struct ErrorKitPolicyTests {
    @Test
    func axolotyErrorUsesThrowableMessages() {
        let error = AxolotyError.invalidArgument(argument: "topic", reason: "invalid topic")

        #expect(error.userFriendlyMessage == "topic: invalid topic")
        #expect(ErrorKit.userFriendlyMessage(for: error) == "topic: invalid topic")
    }

    @Test
    func axolotyErrorRemainsSourceCompatibleAsThrownError() {
        let error: any Error = AxolotyError.runtime(code: .notStarted, reason: "boom")

        #expect((error as? AxolotyError)?.userFriendlyMessage == "boom")
    }

    @Test
    func caughtCaseDelegatesToWrappedErrorMessage() {
        let wrapped = AxolotyError.caught(AxolotyError.decodingFailure(type: "Payload", reason: "bad payload"))

        #expect(wrapped.userFriendlyMessage == "Payload: bad payload")
        #expect(ErrorKit.userFriendlyMessage(for: wrapped) == "Payload: bad payload")
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

    /// Golden `userFriendlyMessage` composition per case, including every
    /// `RuntimeErrorCode` branch. Locks the "argument: reason" shape so a
    /// future edit to the composition doesn't silently regress it.
    @Test
    func userFriendlyMessageIsComposedPerCase() {
        #expect(
            AxolotyError.invalidArgument(argument: "topic", reason: "malformed").userFriendlyMessage
                == "topic: malformed"
        )
        #expect(
            AxolotyError.decodingFailure(type: "AssociateEventData", reason: "bad shape").userFriendlyMessage
                == "AssociateEventData: bad shape"
        )
        #expect(
            AxolotyError.invalidConfiguration(option: "mqttClientOptions", reason: "missing").userFriendlyMessage
                == "mqttClientOptions: missing"
        )

        // `.runtime` renders as the reason alone, independent of the code --
        // the code is for programmatic branching, not message composition.
        for code in AxolotyError.RuntimeErrorCode.allCases {
            #expect(AxolotyError.runtime(code: code, reason: "boom").userFriendlyMessage == "boom")
        }
    }

    /// A foreign error wrapped at a boundary surfaces as `.caught`, and its
    /// chain description (not just its top-level message) is reachable
    /// through `ErrorKit.errorChainDescription(for:)`.
    @Test
    func caughtBoundaryErrorExposesFullChainDescription() {
        let foreignError = NSError(domain: "com.axoloty.test.transport", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "connection reset by peer"
        ])

        let boundaryError = AxolotyError.caught(foreignError)
        let chainDescription = ErrorKit.errorChainDescription(for: boundaryError)

        #expect(chainDescription.contains("connection reset by peer"))

        guard case let .caught(inner) = boundaryError else {
            Issue.record("Expected .caught, got \(boundaryError)")
            return
        }
        #expect(inner as NSError == foreignError)
    }

    /// A network error preserves the original foreign error while exposing a
    /// composed user-facing reason.
    @Test
    func networkErrorPreservesForeignErrorAndReason() {
        let foreignError = NSError(domain: "com.axoloty.test.transport", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "broker refused subscription"
        ])
        let networkError = AxolotyError.network(
            error: foreignError,
            reason: "Error subscribing to topic test/topic: broker refused subscription"
        )

        #expect(networkError.userFriendlyMessage == "Error subscribing to topic test/topic: broker refused subscription")

        guard case let .network(inner, reason) = networkError else {
            Issue.record("Expected .network, got \(networkError)")
            return
        }
        #expect(inner as NSError == foreignError)
        #expect(reason.contains("test/topic"))
    }
}
