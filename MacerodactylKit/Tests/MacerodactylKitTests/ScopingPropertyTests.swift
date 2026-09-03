import Foundation
import Testing

@testable import MacerodactylKit

/// Property tests (T6.3) for THE security boundary — the authorization engine.
/// Instead of hand-picked cases, generate thousands of random grant matrices and
/// assert the invariants hold for every one:
///
///  1. admin ⇒ can do everything, everywhere;
///  2. no view ⇒ nothing (invisible AND every action denied);
///  3. each permission is independent and requires view: `can(p)` iff the grant
///     is present, has view, and has p's own bit — no permission implies another;
///  4. `visible()` shows exactly the viewable containers, never more.
@Suite struct ScopingPropertyTests {
    private let containers = ["alpha", "bravo", "charlie", "delta", "echo", "ghost-never-granted"]
    private let perms = ContainerPermission.allCases

    private func randomGrant(_ rng: inout SplitMix64) -> ContainerGrant {
        ContainerGrant(
            view: Bool.random(using: &rng), power: Bool.random(using: &rng),
            files: Bool.random(using: &rng), console: Bool.random(using: &rng),
            schedules: Bool.random(using: &rng), lifecycle: Bool.random(using: &rng))
    }

    @Test func randomGrantMatricesUpholdEveryInvariant() {
        var rng = SplitMix64(seed: 0xA55E_5D_1234)
        for _ in 0..<5_000 {
            // A random subset of containers get random grants; the rest are ungranted.
            var grants: [String: ContainerGrant] = [:]
            for name in containers where Bool.random(using: &rng) {
                grants[name] = randomGrant(&rng)
            }
            let engine = AuthorizationEngine(isAdmin: false, grants: grants)

            for name in containers {
                let grant = grants[name]
                let hasView = grant?.view ?? false

                // (2) + (3): can(p) iff view AND that permission's own bit.
                for p in perms {
                    let expected = hasView && (grant?.allows(p) ?? false)
                    #expect(engine.can(p, containerNamed: name) == expected)
                }
                // (2): without view, the container is invisible and nothing works.
                if !hasView {
                    #expect(!engine.canView(containerNamed: name))
                    for p in perms { #expect(!engine.can(p, containerNamed: name)) }
                }
            }

            // (4): visible() is exactly the viewable set — never leaks an ungranted one.
            let docs = containers.map {
                DockerContainer(
                    id: $0, name: $0, image: "x", state: .running, status: "Up", health: nil,
                    ports: "", composeProject: nil, composeService: nil, composeWorkingDir: nil)
            }
            let visibleNames = Set(engine.visible(docs).map(\.name))
            let expectedVisible = Set(containers.filter { grants[$0]?.view == true })
            #expect(visibleNames == expectedVisible)
        }
    }

    @Test func adminCanDoEverythingOnAnyContainerRegardlessOfGrants() {
        var rng = SplitMix64(seed: 0x00D_1234_5678)
        for _ in 0..<1_000 {
            var grants: [String: ContainerGrant] = [:]
            for name in containers where Bool.random(using: &rng) { grants[name] = randomGrant(&rng) }
            let admin = AuthorizationEngine(isAdmin: true, grants: grants)
            for name in containers + ["totally-unknown"] {
                #expect(admin.canView(containerNamed: name))
                for p in perms { #expect(admin.can(p, containerNamed: name)) }
            }
        }
    }

    @Test func noPermissionImpliesAnotherIsExhaustivelyTrue() {
        // For every single-permission grant (view + exactly one other), only that
        // one action is allowed — the strongest statement of independence.
        for p in perms where p != .view {
            var g = ContainerGrant(view: true)
            switch p {
            case .view: break
            case .power: g.power = true
            case .files: g.files = true
            case .console: g.console = true
            case .schedules: g.schedules = true
            case .lifecycle: g.lifecycle = true
            case .backups: g.backups = true
            }
            let engine = AuthorizationEngine(isAdmin: false, grants: ["c": g])
            for other in perms where other != .view && other != p {
                #expect(!engine.can(other, containerNamed: "c"), "\(p) must not imply \(other)")
            }
            #expect(engine.can(p, containerNamed: "c"))
        }
    }
}
