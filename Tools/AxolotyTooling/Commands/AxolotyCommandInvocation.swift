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
    case testOne(filter: String)
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
        if arguments.count == 3, arguments[0] == "test-one", arguments[1] == "--filter" {
            return .testOne(filter: arguments[2])
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
        case ["test-one"]:
            return .testOne(filter: environment["FILTER"] ?? "")
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
}

// swiftlint:enable cyclomatic_complexity function_body_length
