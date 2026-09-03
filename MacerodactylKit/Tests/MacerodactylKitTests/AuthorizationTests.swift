import Foundation
import Testing

@testable import MacerodactylKit

private func makeContainer(name: String, project: String? = nil, workingDir: String? = nil) -> DockerContainer {
    DockerContainer(
        id: name + "-id", name: name, image: "img", state: .running,
        status: "Up 1 minute", health: nil, ports: "",
        composeProject: project, composeService: project, composeWorkingDir: workingDir
    )
}

@Suite struct AuthorizationEngineTests {
    let containers = [
        makeContainer(name: "scraper", project: "scraper"),
        makeContainer(name: "bot", project: "bot"),
        makeContainer(name: "bare"),
    ]

    @Test func adminSeesAndDoesEverything() {
        let admin = AuthorizationEngine(isAdmin: true)
        #expect(admin.visible(containers).count == 3)
        for permission in ContainerPermission.allCases {
            #expect(admin.can(permission, containerNamed: "bot"))
        }
    }

    @Test func ungrantedContainerIsInvisibleAndUntouchable() {
        let engine = AuthorizationEngine(
            isAdmin: false,
            grants: [
                "bot": ContainerGrant(view: true, power: true)
            ])
        #expect(engine.visible(containers).map(\.name) == ["bot"])
        #expect(!engine.canView(containerNamed: "scraper"))
        for permission in ContainerPermission.allCases {
            #expect(!engine.can(permission, containerNamed: "scraper"))
            #expect(!engine.can(permission, containerNamed: "does-not-exist"))
        }
    }

    @Test func permissionsAreIndependent() {
        let engine = AuthorizationEngine(
            isAdmin: false,
            grants: [
                "bot": ContainerGrant(view: true, power: false, files: true, console: false)
            ])
        #expect(engine.can(.view, containerNamed: "bot"))
        #expect(!engine.can(.power, containerNamed: "bot"))
        #expect(engine.can(.files, containerNamed: "bot"))
        #expect(!engine.can(.console, containerNamed: "bot"))
    }

    @Test func lifecycleIsIndependentAndRequiresView() {
        // lifecycle does NOT come with power, and like every permission it needs
        // view — "can restart" must never imply "can destroy".
        let withLifecycle = AuthorizationEngine(
            isAdmin: false, grants: ["bot": ContainerGrant(view: true, power: true, lifecycle: false)])
        #expect(withLifecycle.can(.power, containerNamed: "bot"))
        #expect(!withLifecycle.can(.lifecycle, containerNamed: "bot"))

        let granted = AuthorizationEngine(
            isAdmin: false, grants: ["bot": ContainerGrant(view: true, lifecycle: true)])
        #expect(granted.can(.lifecycle, containerNamed: "bot"))
        #expect(!granted.can(.power, containerNamed: "bot"))  // independent

        // lifecycle without view leaks nothing.
        let noView = AuthorizationEngine(
            isAdmin: false, grants: ["bot": ContainerGrant(view: false, lifecycle: true)])
        #expect(!noView.can(.lifecycle, containerNamed: "bot"))
    }

    @Test func intersectionIsTheDelegationCeiling() {
        // A delegated grant can never exceed the granter's own permissions.
        let ceiling = ContainerGrant(view: true, power: true, console: true)  // no files/backups
        let requested = ContainerGrant(view: true, power: true, files: true, backups: true)
        let granted = requested.intersection(with: ceiling)
        #expect(granted.view && granted.power)
        #expect(!granted.files && !granted.backups)  // clamped away — granter lacked them
        #expect(!granted.console)  // not requested, so absent even though the ceiling had it

        // set(_:_:) round-trips every case.
        var g = ContainerGrant()
        for perm in ContainerPermission.allCases { g.set(perm, true) }
        #expect(!g.isEmpty && g.view && g.power && g.files && g.console && g.schedules && g.lifecycle && g.backups)
        g.set(.files, false)
        #expect(!g.files)
    }

    @Test func nothingWorksWithoutView() {
        // A malformed grant (power without view) must not leak anything.
        let engine = AuthorizationEngine(
            isAdmin: false,
            grants: [
                "bot": ContainerGrant(view: false, power: true, files: true, console: true)
            ])
        #expect(engine.visible(containers).isEmpty)
        for permission in ContainerPermission.allCases {
            #expect(!engine.can(permission, containerNamed: "bot"))
        }
    }

    @Test func groupFilteringDropsEmptyStacks() {
        let groups = DockerPSParser.group(containers)
        let engine = AuthorizationEngine(
            isAdmin: false,
            grants: [
                "scraper": ContainerGrant(view: true)
            ])
        let filtered = engine.visible(groups)
        #expect(filtered.stacks.map(\.name) == ["scraper"])
        #expect(filtered.unmanaged.isEmpty)
    }
}

@Suite struct PanelDataStoreTests {
    private func makeStore() throws -> PanelDataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PanelDataStore(databasePath: dir.appending(path: "test.sqlite").path)
    }

    @Test func userAndGrantRoundTrip() throws {
        let store = try makeStore()
        #expect(try !store.hasAnyUser())
        let user = try store.createUser(username: "alice", passwordHash: "hash", isAdmin: false)
        #expect(try store.hasAnyUser())
        #expect(try store.user(named: "alice")?.id == user.id)

        try store.setGrant(
            userID: user.id, containerName: "bot",
            grant: ContainerGrant(view: true, power: true))
        let engine = try store.authorizationEngine(for: user)
        #expect(engine.can(.power, containerNamed: "bot"))
        #expect(!engine.can(.files, containerNamed: "bot"))
        #expect(!engine.canView(containerNamed: "scraper"))

        // Emptying a grant removes the row entirely.
        try store.setGrant(userID: user.id, containerName: "bot", grant: ContainerGrant())
        #expect(try store.grants(forUserID: user.id).isEmpty)
    }

    @Test func sessionsExpireAndAuditRecords() throws {
        let store = try makeStore()
        let user = try store.createUser(username: "bob", passwordHash: "h", isAdmin: true)
        try store.insertSession(tokenHash: "t1", userID: user.id, expiresAt: "2999-01-01T00:00:00Z")
        try store.insertSession(tokenHash: "t2", userID: user.id, expiresAt: "2000-01-01T00:00:00Z")
        let now = "2026-01-01T00:00:00Z"
        #expect(try store.sessionUser(tokenHash: "t1", now: now)?.username == "bob")
        #expect(try store.sessionUser(tokenHash: "t2", now: now) == nil)
        try store.deleteSession(tokenHash: "t1")
        #expect(try store.sessionUser(tokenHash: "t1", now: now) == nil)

        try store.recordAudit(
            username: "bob", action: "power.stop", containerName: "bot",
            outcome: "ok", sourceIP: "203.0.113.9")
        let entries = try store.listAudit()
        #expect(entries.count == 1)
        #expect(entries.first?.action == "power.stop")
        #expect(entries.first?.containerName == "bot")
    }
}
