import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct ContainerExitInfoTests {
    /// The output shape of `docker inspect --format '{{.RestartCount}}\t{{json .State}}'`.
    private func output(restart: Int, state: String) -> String { "\(restart)\t\(state)" }

    @Test func parsesAnOOMKill() {
        let info = ContainerExitInfo.parse(
            inspectOutput: output(
                restart: 3,
                state: #"{"Status":"exited","ExitCode":137,"OOMKilled":true,"Error":"","FinishedAt":"2026-09-03T04:00:00.5Z"}"#))
        let i = try! #require(info)
        #expect(i.oomKilled && i.crashed)
        #expect(i.exitCode == 137 && i.restartCount == 3)
        #expect(i.reason == "Out of memory (OOM-killed)")
        #expect(i.finishedAt == "2026-09-03T04:00:00.5Z")
    }

    @Test func parsesANonZeroCrash() {
        let info = ContainerExitInfo.parse(
            inspectOutput: output(restart: 0, state: #"{"ExitCode":1,"OOMKilled":false,"Error":"","FinishedAt":"2026-09-03T04:00:00Z"}"#))
        let i = try! #require(info)
        #expect(i.crashed && !i.oomKilled)
        #expect(i.reason == "Crashed (exit code 1)")
    }

    @Test func aCleanExitIsNotACrash() {
        let info = ContainerExitInfo.parse(
            inspectOutput: output(restart: 0, state: #"{"ExitCode":0,"OOMKilled":false,"Error":"","FinishedAt":"2026-09-03T04:00:00Z"}"#))
        let i = try! #require(info)
        #expect(!i.crashed)
        #expect(i.reason == nil)
    }

    @Test func neverRunHasNoFinishTime() {
        // docker's zero time means the container has never run.
        let info = ContainerExitInfo.parse(
            inspectOutput: output(restart: 0, state: #"{"ExitCode":0,"OOMKilled":false,"Error":"","FinishedAt":"0001-01-01T00:00:00Z"}"#))
        #expect(info?.finishedAt == nil)
    }

    @Test func surfacesAnEngineError() {
        let info = ContainerExitInfo.parse(
            inspectOutput: output(
                restart: 0, state: #"{"ExitCode":0,"OOMKilled":false,"Error":"no such image","FinishedAt":"2026-09-03T04:00:00Z"}"#))
        let i = try! #require(info)
        #expect(i.crashed)
        #expect(i.reason == "Error: no such image")
    }

    @Test func normalSignalledStopIsNotACrash() {
        // 143 (SIGTERM) and 137 (SIGKILL) are how an ordinary stop ends — not a
        // crash unless the kernel OOM-killed it.
        for code in [143, 137, 130] {
            let info = ContainerExitInfo.parse(
                inspectOutput: output(
                    restart: 0, state: #"{"ExitCode":\#(code),"OOMKilled":false,"Error":"","FinishedAt":"2026-09-03T04:00:00Z"}"#))
            #expect(info?.crashed == false, "exit \(code) should read as a normal stop")
            #expect(info?.reason == nil)
        }
        // But a 137 WITH an OOM kill is still surfaced.
        let oom = ContainerExitInfo.parse(
            inspectOutput: output(restart: 0, state: #"{"ExitCode":137,"OOMKilled":true,"Error":"","FinishedAt":"2026-09-03T04:00:00Z"}"#))
        #expect(oom?.crashed == true)
    }

    @Test func malformedOutputReturnsNil() {
        #expect(ContainerExitInfo.parse(inspectOutput: "no tab, not json") == nil)
        #expect(ContainerExitInfo.parse(inspectOutput: "5\tnot-json") == nil)
        #expect(ContainerExitInfo.parse(inspectOutput: "") == nil)
    }
}
