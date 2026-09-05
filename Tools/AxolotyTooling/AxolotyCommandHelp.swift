// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum AxolotyCommandHelp {
    static func usage(executableName: String) -> String {
        usageDocument.replacingOccurrences(of: "axoloty-tool", with: executableName)
    }

    static func timingUsage(executableName: String) -> String {
        timingUsageDocument(executableName: executableName)
    }

    static func serveUsage(topic: AxolotyServeHelpTopic, executableName: String) -> String {
        let usage = switch topic {
        case .mqtt: mqttUsageDocument
        case .mcp: mcpUsageDocument
        case .dev: developmentUsageDocument
        }
        return usage.replacingOccurrences(of: "axoloty-tool", with: executableName)
    }

    static let repositoryValidationUsage = "Usage: axoloty-tool repository validate [--format human|json]\n"

    private static let usageDocument = """
    Usage: axoloty-tool <command>

    Axoloty's typed build and test orchestration CLI.

    Commands:
      help, --help, -h     Show this help.
      version, --version   Show the CLI version.
      check --plan         Print the initial offline check plan as JSON.
      check                Run the initial offline check plan and print JSON.
      verify [--ci]        Run the canonical ordinary or CI verification plan.
      test-one --filter F  Run one bounded Swift suite/test filter.
      test-tier TIER       Run one canonical test tier.
      explain TIER          Print its command graph and execution policies.
      build                Build the host package and its prerequisites.
      test offline         Run the same offline plan as check.
      test tooling         Run offline developer-tool tests and prerequisites.
      test integration     Deprecated; no canonical broker-backed tier is declared.
      wire capture         Run live MQTT captures with pinned reference agents.
      embedded build       Cross-compile the ESP32-C6 firmware on Linux.
      embedded doctor      Verify the container's ESP-IDF build environment.
      embedded verify      Build and verify the ESP32-C6 linker contract.
      hardware check       Run or skip the sporadic hardware smoke check.
      hardware require     Require an attached device and run its smoke check.
      release checkpoint   Run the release checkpoint validation (no hardware).
      release checkpoint-hardware  Run checkpoint with ESP32-C6 smoke test.
         --device PATH      Override AXOLOTY_DEVICE (default: /dev/ttyACM0).
      measure timing        Measure cold/warm hardware-free builds (Linux only).
      repository validate    Validate version, documentation, and architecture authority.
      serve mqtt           Start a local Mosquitto broker in the foreground.
      serve mcp            Start an Axoloty MCP server (stdio or HTTP).
      serve dev            Start MQTT + MCP as a supervised development stack.

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """

    private static func timingUsageDocument(executableName: String) -> String {
        """
        Usage: \(executableName) measure timing [options]

        Measure cold and warm hardware-free build paths on Linux.

        Options:
          --filter FILTER       Focused Swift test filter (default: AxolotyCommandDispatcherTests).
          --scratch-root PATH   Root for isolated per-scenario scratch trees.
          --keep-scratch        Retain scratch trees after measurement.
          --help                Show this help.
        """
    }

    private static let mqttUsageDocument = """
    Usage: axoloty-tool serve mqtt [options]

    Start a local Mosquitto broker in the foreground.

    Options:
      --listen-host HOST  Bind the broker to HOST (default: 127.0.0.1).
      --port PORT         Listen on PORT (default: 1883).
      --output MODE       Use human or json output (default: human).
      --log-level LEVEL   Use error, warning, info, or debug (default: info).
      --help              Show this help.
    """

    private static let mcpUsageDocument = """
    Usage: axoloty-tool serve mcp --transport TRANSPORT [options]

    Start an Axoloty MCP server using stdio or loopback HTTP.

    Options:
      --transport MODE        Use stdio or http (required).
      --listen-host HOST      HTTP bind address (default: 127.0.0.1).
      --listen-port PORT      HTTP listen port (default: 8765).
      --path PATH             HTTP endpoint path (default: /mcp).
      --broker-host HOST      MQTT broker host (default: localhost).
      --broker-port PORT      MQTT broker port (default: 1883).
      --namespace NAMESPACE   Coaty namespace (default: -).
      --connect-timeout TIME  Broker readiness timeout (default: 10s).
      --output MODE           HTTP output: human or json (default: human).
      --help                  Show this help.

    The HTTP-specific options are not valid with --transport stdio.
    """

    private static let developmentUsageDocument = """
    Usage: axoloty-tool serve dev [options]

    Start MQTT and MCP as a supervised local development stack.

    Options:
      --namespace NAMESPACE  Coaty namespace (default: -).
      --mqtt-port PORT       MQTT listen port (default: 1883).
      --mcp-port PORT        MCP HTTP listen port (default: 8765).
      --output MODE          Use human or json output (default: human).
      --help                 Show this help.
    """
}
