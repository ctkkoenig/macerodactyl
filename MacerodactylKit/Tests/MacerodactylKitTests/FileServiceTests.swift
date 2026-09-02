import Foundation
import Testing

@testable import MacerodactylKit

/// The Phase 1 suites proved PathConfinement in isolation; these prove the
/// LIVE file layer enforces the same boundary — every traversal shape is
/// re-run against real FileService reads and writes on disk.
@Suite struct FileServiceTests {
    private struct Fixture {
        let stacksRoot: URL
        let stackDir: URL
        let outside: URL
        let service: FileService
        let cleanup: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "fsvc-\(UUID().uuidString)")
        let stacksRoot = base.appending(path: "stacks")
        let stackDir = stacksRoot.appending(path: "web")
        let outside = base.appending(path: "secret")
        try fm.createDirectory(at: stackDir.appending(path: "config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("top secret".utf8).write(to: outside.appending(path: "creds.txt"))
        try Data("services:\n  nginx:\n    image: nginx\n".utf8)
            .write(to: stackDir.appending(path: "docker-compose.yml"))
        try Data("server {}\n".utf8).write(to: stackDir.appending(path: "config/nginx.conf"))
        try Data("KEY=value\n".utf8).write(to: stackDir.appending(path: ".env"))

        let container = DockerContainer(
            id: "c1", name: "web-nginx-1", image: "nginx", state: .running, status: "Up",
            health: nil, ports: "", composeProject: "web", composeService: "nginx",
            composeWorkingDir: stackDir.path
        )
        let service = try #require(FileService(container: container, stacksRoot: stacksRoot))
        return Fixture(
            stacksRoot: stacksRoot, stackDir: stackDir, outside: outside,
            service: service, cleanup: { try? fm.removeItem(at: base) })
    }

    // MARK: Availability gate

    @Test func unmanagedContainerGetsNoService() {
        let bare = DockerContainer(
            id: "b", name: "fixture-bare", image: "alpine", state: .running, status: "Up",
            health: nil, ports: "", composeProject: nil, composeService: nil, composeWorkingDir: nil
        )
        #expect(FileService(container: bare, stacksRoot: URL(fileURLWithPath: "/tmp/stacks")) == nil)
    }

    @Test func workingDirOutsideStacksRootGetsNoService() {
        let elsewhere = DockerContainer(
            id: "e", name: "app", image: "app", state: .running, status: "Up",
            health: nil, ports: "", composeProject: "app", composeService: "app",
            composeWorkingDir: "/opt/elsewhere/app"
        )
        #expect(FileService(container: elsewhere, stacksRoot: URL(fileURLWithPath: "/tmp/stacks")) == nil)
    }

    // MARK: Round trip

    @Test func listReadWriteRoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        let rootEntries = try service.list()
        #expect(rootEntries.map(\.name) == ["config", ".env", "docker-compose.yml"])
        #expect(rootEntries.first?.isDirectory == true)

        let nested = try service.list("config")
        #expect(nested.map(\.relativePath) == ["config/nginx.conf"])

        let content = try service.read("docker-compose.yml")
        #expect(content.text.contains("image: nginx"))
        #expect(content.lineEnding == .lf)

        try service.write("docker-compose.yml", text: content.text + "    restart: unless-stopped\n", lineEnding: content.lineEnding)
        #expect(try service.read("docker-compose.yml").text.hasSuffix("restart: unless-stopped\n"))

        // New file in an existing directory.
        try service.write("config/extra.conf", text: "x", lineEnding: .lf)
        #expect(try service.read("config/extra.conf").text == "x")
    }

    // MARK: Confinement at the live layer

    @Test func traversalShapesAreRejectedOnReadAndWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        let escapes = ["../secret/creds.txt", "config/../../secret/creds.txt", "%2e%2e/secret/creds.txt", "..%2fsecret/creds.txt"]
        for path in escapes {
            #expect(throws: FileServiceError.escapesRoot) { _ = try service.read(path) }
            #expect(throws: FileServiceError.escapesRoot) { try service.write(path, text: "x", lineEnding: .lf) }
        }
        for path in ["/etc/passwd", "~/anything", "config\0/nginx.conf"] {
            #expect(throws: FileServiceError.invalidPath) { _ = try service.read(path) }
            #expect(throws: FileServiceError.invalidPath) { try service.write(path, text: "x", lineEnding: .lf) }
        }
        #expect(throws: FileServiceError.escapesRoot) { _ = try service.list("..") }

        // Nothing outside actually changed.
        #expect(try Data(contentsOf: fixture.outside.appending(path: "creds.txt")) == Data("top secret".utf8))
    }

    @Test func symlinkEscapesAreRejectedOnReadAndWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default

        try fm.createSymbolicLink(
            at: fixture.stackDir.appending(path: "sneaky"),
            withDestinationURL: fixture.outside
        )
        #expect(throws: FileServiceError.escapesRoot) { _ = try fixture.service.read("sneaky/creds.txt") }
        #expect(throws: FileServiceError.escapesRoot) { _ = try fixture.service.list("sneaky") }
        #expect(throws: FileServiceError.escapesRoot) {
            try fixture.service.write("sneaky/injected.txt", text: "x", lineEnding: .lf)
        }

        // Dangling symlink leaf pointing outside: a write through it would
        // create a file outside the root.
        try fm.createSymbolicLink(
            at: fixture.stackDir.appending(path: "dangling"),
            withDestinationURL: fixture.outside.appending(path: "not-yet.txt")
        )
        #expect(throws: FileServiceError.escapesRoot) {
            try fixture.service.write("dangling", text: "x", lineEnding: .lf)
        }
        #expect(!fm.fileExists(atPath: fixture.outside.appending(path: "not-yet.txt").path))
    }

    // MARK: Boring cases done properly

    @Test func sizeLimitIsEnforcedBeforeReading() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let big = Data(repeating: UInt8(ascii: "a"), count: FileService.maxEditableBytes + 1)
        try big.write(to: fixture.stackDir.appending(path: "big.log"))
        #expect(
            throws: FileServiceError.tooLarge(
                actualBytes: FileService.maxEditableBytes + 1,
                limitBytes: FileService.maxEditableBytes
            )
        ) {
            _ = try fixture.service.read("big.log")
        }
    }

    @Test func binaryFilesAreRefused() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // NUL bytes (jar/image shape)…
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x01]).write(to: fixture.stackDir.appending(path: "plugin.jar"))
        #expect(throws: FileServiceError.binaryFile) { _ = try fixture.service.read("plugin.jar") }
        // …and NUL-free but not valid UTF-8.
        try Data([0xFF, 0xFE, 0xC0, 0xC1]).write(to: fixture.stackDir.appending(path: "weird.bin"))
        #expect(throws: FileServiceError.binaryFile) { _ = try fixture.service.read("weird.bin") }
    }

    @Test func crlfLineEndingsSurviveEditing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try Data("line one\r\nline two\r\n".utf8).write(to: fixture.stackDir.appending(path: "win.ini"))

        let content = try fixture.service.read("win.ini")
        #expect(content.lineEnding == .crlf)
        #expect(content.text == "line one\nline two\n")  // normalized for the editor

        try fixture.service.write("win.ini", text: content.text + "line three\n", lineEnding: content.lineEnding)
        let raw = try Data(contentsOf: fixture.stackDir.appending(path: "win.ini"))
        #expect(String(decoding: raw, as: UTF8.self) == "line one\r\nline two\r\nline three\r\n")
    }

    @Test func atomicWriteLeavesNoTempDroppings() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.service.write("docker-compose.yml", text: "replaced\n", lineEnding: .lf)
        #expect(try fixture.service.read("docker-compose.yml").text == "replaced\n")
        let leftovers = try fixture.service.list().filter { $0.name.contains("mcdtmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func modificationDateSupportsExternalChangeDetection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let before = try #require(fixture.service.modificationDate("docker-compose.yml"))
        Thread.sleep(forTimeInterval: 0.05)
        try Data("changed externally\n".utf8).write(to: fixture.stackDir.appending(path: "docker-compose.yml"))
        let after = try #require(fixture.service.modificationDate("docker-compose.yml"))
        #expect(after > before)
    }
}
