//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CommunicationState.swift
//  Axoloty
//
//

import Foundation

/// CommunicationState indicates the connectivity state of a CommunicationManager.
public enum CommunicationState: Sendable, Hashable {

    /// Not connected
    case offline

    /// Connected
    case online

}
