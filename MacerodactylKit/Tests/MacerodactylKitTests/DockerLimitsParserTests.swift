import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct DockerLimitsParserTests {
    @Test func parsesMemoryAndCPUAndUnlimited() {
        // name|memory|nanoCpus|cpuQuota|cpuPeriod
        let output = """
            /web|536870912|2000000000|0|100000
            /db|0|0|50000|100000
            /free|0|0|0|0
            """
        let limits = DockerLimitsParser.parse(output)
        // web: 512 MiB, 2 cores (from NanoCpus).
        #expect(limits["web"]?.memoryBytes == 536_870_912)
        #expect(limits["web"]?.cpuCores == 2)
        // db: unlimited memory, 0.5 cores (from quota/period).
        #expect(limits["db"]?.memoryBytes == nil)
        #expect(limits["db"]?.cpuCores == 0.5)
        // free: unlimited both.
        #expect(limits["free"]?.memoryBytes == nil)
        #expect(limits["free"]?.cpuCores == nil)
    }

    @Test func toleratesGarbageLines() {
        #expect(DockerLimitsParser.parse("").isEmpty)
        #expect(DockerLimitsParser.parse("nonsense\n|||\n/x|abc|def|ghi|jkl").count <= 1)
    }
}
