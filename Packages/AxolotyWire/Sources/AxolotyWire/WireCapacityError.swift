// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A structured, allocation-free error for caller-controlled capacity and
/// count bounds in the embedded wire routing path.
///
/// Construction-time validation of routing capacities and fixed endpoint
/// counts rejects out-of-range values with this error instead of trapping
/// or falling back to an unsafe configuration. Like ``WireDecodeError`` it is
/// allocation-free and Sendable, so it is safe to throw across the embedded
/// firmware/host boundary.
public struct WireCapacityError: Error, Sendable {
    /// The machine-readable failure reason.
    public let reason: Reason
    /// The name of the capacity or count parameter that was out of range.
    public let parameter: StaticString

    /// The categorized cause of a capacity-validation failure.
    public enum Reason: Sendable, Equatable {
        /// The parameter was negative.
        case negativeCapacity
        /// The parameter exceeded its configured maximum.
        case exceedsMaximum
        /// Two counts that must match did not (e.g. actors vs. actor handlers).
        case countMismatch
    }

    /// Creates a capacity-validation error.
    ///
    /// - Parameters:
    ///   - reason: The categorized failure reason.
    ///   - parameter: The name of the capacity or count parameter.
    public init(_ reason: Reason, parameter: StaticString) {
        self.reason = reason
        self.parameter = parameter
    }
}
