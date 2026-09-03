import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct StartupProbeTests {
    @Test func doneMarkerDetection() {
        #expect(StartupProbe.isDone(logText: "…\n)! For help, type", doneStrings: [")! For help,"]))
        #expect(!StartupProbe.isDone(logText: "still booting", doneStrings: [")! For help,"]))
        // No markers → never "done" (caller then shows no startup state at all).
        #expect(!StartupProbe.isDone(logText: "anything", doneStrings: []))
        #expect(!StartupProbe.isDone(logText: "anything", doneStrings: [""]))
    }

    @Test func onlineWhenMarkerSeen() {
        let s = StartupProbe.evaluate(
            logText: "Done (5.1s)! For help", doneStrings: ["Done ("], uptimeSeconds: 3)
        #expect(s == .online)
    }

    @Test func startingWhenMarkerAbsentAndFresh() {
        let s = StartupProbe.evaluate(
            logText: "Loading libraries…", doneStrings: ["Done ("], uptimeSeconds: 4, graceSeconds: 180)
        #expect(s == .starting)
    }

    @Test func onlineByUptimeFallbackWhenMarkerScrolledAway() {
        // No marker in the (truncated) tail, but it's been up 20 min — not still
        // "starting"; the done line just aged out of the window.
        let s = StartupProbe.evaluate(
            logText: "…tail with no marker…", doneStrings: ["Done ("], uptimeSeconds: 1200, graceSeconds: 180)
        #expect(s == .online)
    }

    @Test func unknownUptimeStaysStartingUntilMarker() {
        let s = StartupProbe.evaluate(
            logText: "booting", doneStrings: ["Done ("], uptimeSeconds: nil)
        #expect(s == .starting)
    }
}
