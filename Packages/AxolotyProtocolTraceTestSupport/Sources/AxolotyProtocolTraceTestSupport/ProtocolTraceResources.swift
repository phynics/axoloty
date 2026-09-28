// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

enum ProtocolTraceResources {
    static var schemaURL: URL? {
        Bundle.module.url(forResource: "trace.schema", withExtension: "json")
    }
}
