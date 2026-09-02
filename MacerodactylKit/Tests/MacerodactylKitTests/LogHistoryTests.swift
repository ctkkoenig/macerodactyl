import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct LogHistoryTests {
    @Test func mergesTwoStreamsByTimestamp() {
        // docker writes app output to BOTH stdout and stderr; --timestamps lets
        // us interleave them back into one chronological log.
        let stdout = "2026-09-02T10:00:00Z line-a\n2026-09-02T10:00:02Z line-c"
        let stderr = "2026-09-02T10:00:01Z line-b\n2026-09-02T10:00:03Z line-d"
        let merged = LogStreamService.mergeChronologically(stdout: stdout, stderr: stderr)
        #expect(
            merged
                == [
                    "2026-09-02T10:00:00Z line-a",
                    "2026-09-02T10:00:01Z line-b",
                    "2026-09-02T10:00:02Z line-c",
                    "2026-09-02T10:00:03Z line-d",
                ].joined(separator: "\n"))
    }

    @Test func stableForEqualTimestampsAndHandlesEmpty() {
        let same = "2026-09-02T10:00:00Z first\n2026-09-02T10:00:00Z second"
        #expect(LogStreamService.mergeChronologically(stdout: same, stderr: "") == same)
        #expect(LogStreamService.mergeChronologically(stdout: "", stderr: "") == "")
    }
}
