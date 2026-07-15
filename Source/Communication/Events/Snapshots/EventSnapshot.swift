// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A marker protocol for immutable, value-typed snapshots of communication events
/// that can be safely shared across concurrency domains.
public protocol EventSnapshot: Sendable {}
