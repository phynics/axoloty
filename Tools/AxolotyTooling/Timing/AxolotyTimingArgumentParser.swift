// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses the argument tail of `measure timing`.
public enum AxolotyTimingArgumentParser {
    /// Parses timing options without touching the filesystem or launching a process.
    /// - Parameter arguments: The argument tail following `measure timing`.
    /// - Returns: Parsed options or one stable parse failure.
    public static func parse(_ arguments: [String]) -> AxolotyTimingArgumentParseResult {
        var filter = AxolotyTimingOptions().filter
        var scratchRoot: String?
        var keepScratch = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--filter":
                guard index + 1 < arguments.count else {
                    return AxolotyTimingArgumentParseResult(failure: .missingValue(argument))
                }
                index += 1
                guard !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    return AxolotyTimingArgumentParseResult(failure: .emptyValue(argument))
                }
                filter = arguments[index]
            case "--scratch-root":
                guard index + 1 < arguments.count else {
                    return AxolotyTimingArgumentParseResult(failure: .missingValue(argument))
                }
                index += 1
                guard !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    return AxolotyTimingArgumentParseResult(failure: .emptyValue(argument))
                }
                scratchRoot = arguments[index]
            case "--keep-scratch":
                keepScratch = true
            default:
                return AxolotyTimingArgumentParseResult(failure: .unsupportedOption(argument))
            }
            index += 1
        }

        return AxolotyTimingArgumentParseResult(
            success: AxolotyTimingOptions(
                filter: filter,
                scratchRoot: scratchRoot,
                keepScratch: keepScratch
            )
        )
    }
}
