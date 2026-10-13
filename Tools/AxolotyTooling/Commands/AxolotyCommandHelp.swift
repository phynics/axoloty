// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum AxolotyCommandHelp {
    static func usage(executableName: String) -> String {
        usageDocument.replacingOccurrences(of: "axoloty-tool", with: executableName)
    }


    static let repositoryValidationUsage = "Usage: axoloty-tool repository validate [--embedded-consumer-contract] [--format human|json]\n"

    private static let usageDocument = """
    Usage: axoloty-tool <command>

    Axoloty's typed build and test orchestration CLI.

    Commands:
      help, --help, -h     Show this help.
      version, --version   Show the CLI version.
      check --plan         Print the initial offline check plan as JSON.
      check                Run the initial offline check plan and print JSON.
      verify [--ci]        Run the canonical ordinary or CI verification plan.
      test-one --filter F [--maximum-repetitions N] [--repeat-until pass|fail]
                           Run one bounded Swift test filter, optionally repeated.
      test-tier TIER       Run one canonical test tier.
      explain TIER          Print its command graph and execution policies.
      build                Build the host package and its prerequisites.
      test tooling         Run offline developer-tool tests and prerequisites.
      wire capture         Run live MQTT captures with pinned reference agents.
      zenoh live           Run the opt-in pinned zenohd integration suite.
      zenoh offline        Run the router-free Zenoh package tests on pinned zenoh-c.
      embedded consumer prepare  Prepare a standalone Embedded Swift consumer report.
      release checkpoint   Run the release checkpoint validation (no hardware).
      repository validate    Validate version, documentation, and architecture authority.

    The runtime/debug services (serve mqtt|mcp|dev) live in the sibling
    axoloty-debug package and are reached through its axoloty-debug command.

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """
}
