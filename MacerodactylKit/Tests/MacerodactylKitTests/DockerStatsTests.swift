import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ByteParsingTests {
    @Test func parsesBinaryUnits() {
        #expect(DockerStatsParser.parseBytes("1KiB") == 1024)
        #expect(DockerStatsParser.parseBytes("1.5MiB") == 1.5 * 1_048_576)
        #expect(DockerStatsParser.parseBytes("2GiB") == 2.0 * 1_073_741_824)
    }

    @Test func parsesDecimalUnits() {
        #expect(DockerStatsParser.parseBytes("1kB") == 1_000)
        #expect(DockerStatsParser.parseBytes("3.4MB") == 3_400_000)
        #expect(DockerStatsParser.parseBytes("0B") == 0)
    }

    @Test func handlesWhitespaceAndPlainBytes() {
        #expect(DockerStatsParser.parseBytes(" 512B ") == 512)
        #expect(DockerStatsParser.parseBytes("42") == 42)
    }

    @Test func rejectsGarbage() {
        #expect(DockerStatsParser.parseBytes("") == nil)
        #expect(DockerStatsParser.parseBytes("MiB") == nil)
    }

    @Test func percentAndPair() {
        #expect(DockerStatsParser.parsePercent("12.34%") == 12.34)
        #expect(DockerStatsParser.parsePercent("--") == nil)
        let pair = DockerStatsParser.splitPair("1.5MiB / 512MiB")
        #expect(pair?.0 == "1.5MiB" && pair?.1 == "512MiB")
    }
}

@Suite struct DockerStatsLineTests {
    private func line(_ dict: [String: String]) -> String {
        String(decoding: try! JSONEncoder().encode(dict), as: UTF8.self)
    }

    @Test func parsesAFullLine() {
        let json = line([
            "Name": "web", "CPUPerc": "3.21%", "MemUsage": "45.5MiB / 512MiB",
            "MemPerc": "8.89%", "NetIO": "1.2kB / 3.4kB", "PIDs": "7",
        ])
        let stats = DockerStatsParser.parse(line: json)
        #expect(stats?.name == "web")
        #expect(stats?.cpuPercent == 3.21)
        #expect(stats?.memUsedBytes == 45.5 * 1_048_576)
        #expect(stats?.memLimitBytes == 512.0 * 1_048_576)
        #expect(stats?.netRxBytes == 1_200)
        #expect(stats?.netTxBytes == 3_400)
        #expect(stats?.pids == 7)
    }

    @Test func lineWithoutMemoryIsNotAReading() {
        // A stopped/absent container yields nil — never a zeroed reading.
        #expect(DockerStatsParser.parse(line: line(["Name": "dead", "CPUPerc": "0.00%"])) == nil)
        #expect(DockerStatsParser.parse(line: "not json") == nil)
    }

    @Test func snapshotKeysByNameSkippingUnreadable() {
        let output = [
            line(["Name": "a", "CPUPerc": "1%", "MemUsage": "10MiB / 100MiB", "NetIO": "0B / 0B", "PIDs": "1"]),
            "garbage line",
            line(["Name": "b", "CPUPerc": "2%", "MemUsage": "20MiB / 100MiB", "NetIO": "0B / 0B", "PIDs": "2"]),
        ].joined(separator: "\n")
        let snap = DockerStatsParser.parseSnapshot(output)
        #expect(Set(snap.keys) == ["a", "b"])
        #expect(snap["b"]?.memUsedBytes == 20.0 * 1_048_576)
    }

    @Test func computesMemPercentWhenAbsent() {
        let json = line(["Name": "x", "CPUPerc": "0%", "MemUsage": "50MiB / 200MiB", "NetIO": "0B / 0B", "PIDs": "1"])
        let stats = DockerStatsParser.parse(line: json)
        #expect(stats?.memPercent == 25)  // 50/200
    }
}

@Suite struct PowerActionTests {
    @Test func killIsDestructiveAndDistinct() {
        #expect(ContainerStore.PowerAction.kill.isDestructive)
        #expect(!ContainerStore.PowerAction.stop.isDestructive)
        #expect(ContainerStore.PowerAction.allCases.contains(.kill))
        #expect(ContainerStore.PowerAction.kill.rawValue == "kill")  // maps to `docker kill`
    }
}
