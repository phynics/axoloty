// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import AxolotyTransportContractTestSupport

@Suite("Runtime transport contract")
struct RuntimeTransportContractTests {
    @Test("TestTransport satisfies the shared runtime transport contract")
    func testTransportContract() async throws {
        try await runRuntimeTransportContract(using: TestTransport())
    }
}
