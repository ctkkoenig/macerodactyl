import Foundation
import Testing

@testable import MacerodactylKit

/// Each cold-start environment is faked and asserted to explain itself, rather
/// than only exercising the happy path on a working machine.
@Suite struct StartupDiagnosticsTests {
    private func env(
        dockerResolved: Bool = true, daemon: DockerAvailability = .ready,
        compose: Bool = true, perl: Bool = true, stacks: Bool = true, containers: Int = 3
    ) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            dockerResolved: dockerResolved, daemon: daemon, composeAvailable: compose,
            perlAvailable: perl, stacksRootExists: stacks, stacksRootPath: "/Users/x/stacks",
            containerCount: containers
        )
    }

    @Test func dockerNotInstalledIsBlockingAndAlone() {
        let advisories = StartupDiagnostics.evaluate(env(dockerResolved: false))
        #expect(advisories.map(\.id) == ["docker-missing"])
        #expect(advisories.first?.severity == .blocking)
        #expect(advisories.first?.remedy.contains("Docker Desktop") == true)
    }

    @Test func daemonStoppedIsBlockingAndAlone() {
        let advisories = StartupDiagnostics.evaluate(env(daemon: .daemonDown))
        #expect(advisories.map(\.id) == ["daemon-down"])
        #expect(advisories.first?.severity == .blocking)
    }

    @Test func blockingIssuesSuppressDependentAdvisories() {
        // No point warning about compose/stacks/empty list when docker is absent.
        let advisories = StartupDiagnostics.evaluate(
            env(dockerResolved: false, compose: false, stacks: false, containers: 0))
        #expect(advisories.count == 1)
        #expect(advisories.first?.id == "docker-missing")
    }

    @Test func missingComposeIsDegraded() {
        let advisories = StartupDiagnostics.evaluate(env(compose: false))
        #expect(advisories.contains { $0.id == "compose-missing" && $0.severity == .degraded })
    }

    @Test func missingPerlIsDegradedNotBlocking() {
        let advisories = StartupDiagnostics.evaluate(env(perl: false))
        let perl = advisories.first { $0.id == "perl-missing" }
        #expect(perl?.severity == .degraded)
        #expect(perl?.remedy.contains("still work") == true)  // schedules still run
    }

    @Test func missingStacksFolderIsInfoWithPath() {
        let advisories = StartupDiagnostics.evaluate(env(stacks: false))
        let stacks = advisories.first { $0.id == "stacks-missing" }
        #expect(stacks?.severity == .info)
        #expect(stacks?.detail.contains("/Users/x/stacks") == true)
    }

    @Test func zeroContainersIsInfo() {
        let advisories = StartupDiagnostics.evaluate(env(containers: 0))
        #expect(advisories.contains { $0.id == "no-containers" && $0.severity == .info })
    }

    @Test func healthyEnvironmentHasNoAdvisories() {
        #expect(StartupDiagnostics.evaluate(env()).isEmpty)
    }

    @Test func multipleDegradationsAllReported() {
        let advisories = StartupDiagnostics.evaluate(env(compose: false, perl: false, stacks: false, containers: 0))
        #expect(Set(advisories.map(\.id)) == ["compose-missing", "perl-missing", "stacks-missing", "no-containers"])
    }
}
