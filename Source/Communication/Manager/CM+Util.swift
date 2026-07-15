// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
extension CommunicationManager {

    /// Returns the current communication state.
    public func currentCommunicationState() -> CommunicationState {
        communicationState
    }

    /// Returns the current operating state.
    public func currentOperatingState() -> OperatingState {
        operatingState
    }
}
