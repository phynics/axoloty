// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

// swiftlint:disable cyclomatic_complexity function_body_length

/// A parsed command invocation owned by the command dispatcher.
enum AxolotyCommandInvocation: Equatable, Sendable {
    case help
    case version
    case unsupported
    case serve(arguments: [String])
    case timing(arguments: [String])
    case repositoryValidation(arguments: [String])
    case testOne(filter: String, repetition: AxolotyTestRepetition?)
    case testTier(name: String, ci: Bool)
    case explain(tier: String, ci: Bool)
    case checkPlan
    case check(requested: [String]?)
    case build
    case testOffline
    case testTooling
    case verify(ci: Bool)
    case integration
    case wireVerify
    case wireCapture
    case embeddedConsumerPrepare(arguments: [String])
    case release(ReleaseCommand)
}

/// The concrete parser for the stable `axoloty-tool` command surface.
struct AxolotyCommandParser: Sendable {
    let environment: [String: String]

    func parse(_ arguments: [String]) -> AxolotyCommandInvocation {
        if arguments.first == "serve" {
            return .serve(arguments: Array(arguments.dropFirst()))
        }
        if arguments.count >= 2, arguments[0] == "measure", arguments[1] == "timing" {
            return .timing(arguments: Array(arguments.dropFirst(2)))
        }
        if arguments.first == "repository", arguments.dropFirst().first == "validate" {
            return .repositoryValidation(arguments: Array(arguments.dropFirst(2)))
        }
        if arguments.first == "test-one" {
            return testOneInvocation(arguments)
        }
        if arguments.count == 2, arguments[0] == "test-tier" {
            return .testTier(name: arguments[1], ci: false)
        }
        if arguments.count == 3, arguments[0] == "test-tier", arguments[1] == "--ci" {
            return .testTier(name: arguments[2], ci: true)
        }
        if arguments.count == 2, arguments[0] == "explain" {
            return .explain(tier: arguments[1], ci: false)
        }
        if arguments.count == 3, arguments[0] == "explain", arguments[1] == "--ci" {
            return .explain(tier: arguments[2], ci: true)
        }
        if arguments.count >= 3,
           arguments[0] == "embedded",
           arguments[1] == "consumer",
           arguments[2] == "prepare" {
            return .embeddedConsumerPrepare(arguments: Array(arguments.dropFirst(3)))
        }

        switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            return .help
        case ["version"], ["--version"]:
            return .version
        case ["check", "--plan"]:
            return .checkPlan
        case ["check"]:
            return .check(requested: nil)
        case ["verify"]:
            return .verify(ci: false)
        case ["verify", "--ci"]:
            return .verify(ci: true)
        case ["test-tier"]:
            return .testTier(name: environment["TIER"] ?? "", ci: false)
        case ["explain"]:
            return .explain(tier: environment["TIER"] ?? "", ci: false)
        case ["build"]:
            return .build
        case ["test", "offline"]:
            return .testOffline
        case ["test", "tooling"]:
            return .testTooling
        case ["test", "integration"]:
            return .integration
        case ["wire", "verify"]:
            return .wireVerify
        case ["wire", "capture"]:
            return .wireCapture
        case ["release", "checkpoint"]:
            return .release(.checkpoint)
        default:
            return .unsupported
        }
    }

    private func testOneInvocation(_ arguments: [String]) -> AxolotyCommandInvocation {
        var filter = environment["FILTER"] ?? ""
        var sawFilter = false
        var maximumRepetitions: Int?
        var repeatUntil: AxolotyTestRepeatCondition?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { return .unsupported }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--filter":
                guard !sawFilter else { return .unsupported }
                filter = value
                sawFilter = true
            case "--maximum-repetitions":
                guard maximumRepetitions == nil,
                      let parsed = Int(value), parsed > 0 else { return .unsupported }
                maximumRepetitions = parsed
            case "--repeat-until":
                guard repeatUntil == nil,
                      let parsed = AxolotyTestRepeatCondition(rawValue: value) else { return .unsupported }
                repeatUntil = parsed
            default:
                return .unsupported
            }
            index += 2
        }
        guard repeatUntil == nil || maximumRepetitions != nil else { return .unsupported }
        let repetition = maximumRepetitions.map { maximum in
            AxolotyTestRepetition(maximumRepetitions: maximum, repeatUntil: repeatUntil)
        }
        return .testOne(filter: filter, repetition: repetition)
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
