// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Injectable boundary for signal handling, enabling test substitution.
public protocol InspectorSignalHandling: AnyObject {
    /// Whether the operator has sent an interruption signal.
    var wasInterrupted: Bool { get }
    /// Installs SIGINT and SIGTERM handlers. Call once at startup.
    func install()
}
