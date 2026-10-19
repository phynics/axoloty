// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Testing

extension AxolotyCheckTests {

    @Test
    func commandPhaseParserReportsBuildAndTestDurations() {
        let timings = AxolotyCommandPhaseTimingParser.parse("""
        Build complete! (2.50 secs)
        ✔ Test first passed after 0.25 seconds.
        Build complete! (1.25 seconds)
        ✘ Test second failed after 0.75 seconds.
        """)

        #expect(timings.compilationSeconds == 3.75)
        #expect(timings.testSeconds == 1)
    }

    @Test
    func commandPhaseParserLeavesUnreportedDurationsAbsent() {
        let timings = AxolotyCommandPhaseTimingParser.parse("shell command completed\n")

        #expect(timings.compilationSeconds == nil)
        #expect(timings.testSeconds == nil)
    }
}
