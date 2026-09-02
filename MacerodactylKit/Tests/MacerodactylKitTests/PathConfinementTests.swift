import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct FileRootTests {
    let stacksRoot = URL(fileURLWithPath: "/tmp/pcf-stacks")

    @Test func composeContainerUnderStacksRootHasRoot() {
        let container = makeContainer(name: "web", project: "web", workingDir: "/tmp/pcf-stacks/web")
        #expect(PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot)?.path == "/tmp/pcf-stacks/web")
    }

    @Test func unmanagedContainerHasNoRoot() {
        let container = makeContainer(name: "bare")
        #expect(PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot) == nil)
    }

    @Test func workingDirOutsideStacksRootHasNoRoot() {
        let container = makeContainer(name: "web", project: "web", workingDir: "/opt/elsewhere/web")
        #expect(PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot) == nil)
    }

    @Test func workingDirEqualToStacksRootHasNoRoot() {
        let container = makeContainer(name: "web", project: "web", workingDir: "/tmp/pcf-stacks")
        #expect(PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot) == nil)
    }

    @Test func traversalInWorkingDirIsNormalizedAndRejected() {
        let container = makeContainer(name: "web", project: "web", workingDir: "/tmp/pcf-stacks/../etc")
        #expect(PathConfinement.fileRoot(for: container, stacksRoot: stacksRoot) == nil)
    }

    private func makeContainer(name: String, project: String? = nil, workingDir: String? = nil) -> DockerContainer {
        DockerContainer(
            id: name, name: name, image: "img", state: .running, status: "Up",
            health: nil, ports: "", composeProject: project, composeService: nil,
            composeWorkingDir: workingDir
        )
    }
}

@Suite struct PathResolutionTests {
    /// A real on-disk root so symlink behavior is exercised for real.
    private func makeRoot() throws -> (root: URL, outside: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "pcf-\(UUID().uuidString)")
        let root = base.appending(path: "stacks/web")
        let outside = base.appending(path: "secret")
        try fm.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("top secret".utf8).write(to: outside.appending(path: "creds.txt"))
        try Data("server {}".utf8).write(to: root.appending(path: "config/nginx.conf"))
        return (root, outside, { try? fm.removeItem(at: base) })
    }

    @Test func plainRelativePathsResolve() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        let url = try PathConfinement.resolve("config/nginx.conf", in: root)
        #expect(url.path.hasSuffix("config/nginx.conf"))
        // A file that doesn't exist yet (about to be written) is fine.
        _ = try PathConfinement.resolve("config/new-file.yml", in: root)
        _ = try PathConfinement.resolve("./docker-compose.yml", in: root)
    }

    @Test func dotDotIsRejected() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("../secret/creds.txt", in: root)
        }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("config/../../secret/creds.txt", in: root)
        }
    }

    @Test func absoluteAndTildeAreRejected() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("/etc/passwd", in: root)
        }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("~/anything", in: root)
        }
    }

    @Test func encodedTraversalIsRejected() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("%2e%2e/secret/creds.txt", in: root)
        }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("..%2fsecret/creds.txt", in: root)
        }
    }

    @Test func nulByteIsRejected() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("config\0/nginx.conf", in: root)
        }
    }

    @Test func symlinkEscapeIsRejected() throws {
        let (root, outside, cleanup) = try makeRoot()
        defer { cleanup() }
        let fm = FileManager.default
        try fm.createSymbolicLink(
            at: root.appending(path: "sneaky"),
            withDestinationURL: outside
        )
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("sneaky/creds.txt", in: root)
        }
        // A dangling symlink leaf pointing outside is rejected too — a write
        // through it would create a file outside the root.
        try fm.createSymbolicLink(
            at: root.appending(path: "dangling"),
            withDestinationURL: outside.appending(path: "not-yet-here.txt")
        )
        #expect(throws: PathConfinementError.self) {
            _ = try PathConfinement.resolve("dangling", in: root)
        }
    }

    @Test func symlinkInsideRootIsAllowed() throws {
        let (root, _, cleanup) = try makeRoot()
        defer { cleanup() }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "conf-link"),
            withDestinationURL: root.appending(path: "config")
        )
        _ = try PathConfinement.resolve("conf-link/nginx.conf", in: root)
    }
}
