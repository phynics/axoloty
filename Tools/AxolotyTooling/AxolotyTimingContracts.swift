// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The build or test operation measured by ``AxolotyTimingRunner``.
public enum AxolotyTimingScenario: String, CaseIterable, Codable, Equatable, Sendable {
    /// The host Swift package build.
    case hostBuild = "host-build"
    /// A focused Swift test build.
    case focusedTestBuild = "focused-test-build"
    /// The hardware-free Embedded Swift build.
    case embeddedBuild = "embedded-build"
    /// The hardware-free ESP-IDF linker validation.
    case linkerValidation = "linker-validation"
}
/// Whether a timing measurement starts from a fresh or reused scratch tree.
public enum AxolotyTimingMode: String, Codable, Equatable, Sendable {
    /// Remove the scenario scratch tree before running.
    case cold
    /// Reuse the scenario scratch tree created by the cold run.
    case warm
}

/// Arguments accepted by `axoloty-tool measure timing`.
public struct AxolotyTimingOptions: Codable, Equatable, Sendable {
    /// The Swift test filter used for the focused test build.
    public let filter: String
    /// An optional root for per-scenario scratch trees.
    public let scratchRoot: String?
    /// Keep scratch trees after the measurement completes.
    public let keepScratch: Bool

    /// Creates timing options.
    ///
    /// - Parameters:
    ///   - filter: Focused Swift test filter.
    ///   - scratchRoot: Optional root for isolated scenario scratch trees.
    ///   - keepScratch: Whether to retain scenario scratch trees.
    public init(
        filter: String = "AxolotyCommandDispatcherTests",
        scratchRoot: String? = nil,
        keepScratch: Bool = false
    ) {
        self.filter = filter
        self.scratchRoot = scratchRoot
        self.keepScratch = keepScratch
    }
}

/// A stable diagnostic produced while parsing timing command arguments.
public enum AxolotyTimingArgumentParserError: Codable, Equatable, Sendable {
    /// An option requiring a value was not followed by one.
    case missingValue(String)
    /// An option is not part of the timing command surface.
    case unsupportedOption(String)
    /// An option value was present but empty.
    case emptyValue(String)

    /// A stable user-facing diagnostic.
    public var message: String {
        switch self {
        case .missingValue(let option): "\(option) requires a value"
        case .unsupportedOption(let option): "unsupported timing option \(option)"
        case .emptyValue(let option): "\(option) must not be empty"
        }
    }
}

/// The success or failure of timing argument parsing.
public struct AxolotyTimingArgumentParseResult: Equatable, Sendable {
    /// Parsed options, or `nil` when parsing failed.
    public let success: AxolotyTimingOptions?
    /// A stable parse error, or `nil` on success.
    public let failure: AxolotyTimingArgumentParserError?

    init(success: AxolotyTimingOptions? = nil, failure: AxolotyTimingArgumentParserError? = nil) {
        self.success = success
        self.failure = failure
    }
}
