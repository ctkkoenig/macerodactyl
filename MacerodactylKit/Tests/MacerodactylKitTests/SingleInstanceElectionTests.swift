import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct SingleInstanceElectionTests {
    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: offset) }

    /// Simulates every copy independently running the election and returns how
    /// many decided to STAY (did not defer). Must always be exactly 1: never zero
    /// (both quit) and never two (both stay).
    private func survivorCount(_ instances: [InstanceInfo]) -> Int {
        instances.reduce(0) { count, current in
            let others = instances.filter { $0.processIdentifier != current.processIdentifier }
            return count + (SingleInstanceElection.shouldDefer(current: current, others: others) ? 0 : 1)
        }
    }

    @Test func identicalLaunchDatesElectExactlyOneByPid() {
        // Bug 1: with `theirs <= mine`, two equal dates made BOTH quit (0 survive).
        let d = date(1000)
        let a = InstanceInfo(processIdentifier: 200, launchDate: d)
        let b = InstanceInfo(processIdentifier: 100, launchDate: d)
        #expect(survivorCount([a, b]) == 1)
        // The lower pid is the deterministic winner; both copies agree.
        #expect(SingleInstanceElection.survivor(among: [a, b])?.processIdentifier == 100)
        #expect(SingleInstanceElection.shouldDefer(current: b, others: [a]) == false)  // pid 100 stays
        #expect(SingleInstanceElection.shouldDefer(current: a, others: [b]) == true)  // pid 200 quits
    }

    @Test func nilLaunchDateNeverBeatsADatedInstance() {
        // Bug 2: a nil launchDate used to make the live (dated) instance yield.
        let live = InstanceInfo(processIdentifier: 500, launchDate: date(2000))
        let ghost = InstanceInfo(processIdentifier: 100, launchDate: nil)  // lower pid, but no date
        #expect(survivorCount([live, ghost]) == 1)
        // The dated instance wins despite the ghost's lower pid.
        #expect(SingleInstanceElection.survivor(among: [live, ghost])?.processIdentifier == 500)
        #expect(SingleInstanceElection.shouldDefer(current: live, others: [ghost]) == false)
        #expect(SingleInstanceElection.shouldDefer(current: ghost, others: [live]) == true)
    }

    @Test func twoNilLaunchDatesStillElectExactlyOneByPid() {
        let a = InstanceInfo(processIdentifier: 300, launchDate: nil)
        let b = InstanceInfo(processIdentifier: 150, launchDate: nil)
        #expect(survivorCount([a, b]) == 1)
        #expect(SingleInstanceElection.survivor(among: [a, b])?.processIdentifier == 150)
    }

    @Test func threeLaunchesElectExactlyOneEarliest() {
        // The existing three-launch case: distinct dates, earliest survives.
        let first = InstanceInfo(processIdentifier: 30, launchDate: date(100))
        let second = InstanceInfo(processIdentifier: 20, launchDate: date(200))
        let third = InstanceInfo(processIdentifier: 10, launchDate: date(300))
        let all = [third, first, second]  // unsorted on purpose
        #expect(survivorCount(all) == 1)
        #expect(SingleInstanceElection.survivor(among: all)?.processIdentifier == 30)  // earliest date, not lowest pid
    }

    @Test func survivingOtherTargetsTheWinnerNotAnArbitraryElement() {
        // Bug 3: activate() used to hit `others.first`, an arbitrary instance.
        let current = InstanceInfo(processIdentifier: 40, launchDate: date(500))  // launched latest
        let winner = InstanceInfo(processIdentifier: 30, launchDate: date(100))  // earliest → survivor
        let noise = InstanceInfo(processIdentifier: 20, launchDate: date(300))
        // `noise` is deliberately first in the others list; the target must be the
        // actual winner, not the first element.
        let target = SingleInstanceElection.survivingOther(current: current, others: [noise, winner])
        #expect(target?.processIdentifier == 30)
    }

    @Test func theSurvivorItselfNeverDefers() {
        let winner = InstanceInfo(processIdentifier: 30, launchDate: date(100))
        let other = InstanceInfo(processIdentifier: 20, launchDate: date(300))
        // The winner, asked to defer, refuses (nil target → stays).
        #expect(SingleInstanceElection.survivingOther(current: winner, others: [other]) == nil)
    }
}
